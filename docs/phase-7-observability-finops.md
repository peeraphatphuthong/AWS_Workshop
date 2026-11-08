# Phase 7 — Observability & FinOps

Goal: know that the system is broken **before users tell you**, be able to find out **why** from logs and
metrics, and stop paying for things nobody uses.

## What was built
```
                       ┌──────────── EventBridge Scheduler (group aws-workshop-dev) ────────────┐
                       │ healthcheck: rate(5 min) ─► Lambda ─► GET http://EIP/readyz             │
                       │ office hours (Asia/Bangkok): 07:30 start RDS · 08:00 start EC2         │
                       │                              22:00 stop EC2  · 22:10 stop RDS          │
                       └────────────────────────────────────────────────────────────────────────┘
EC2 (docker awslogs) ─► Logs /retail-health/dev/containers ─► metric filter Nginx5xx
RDS error/slowquery  ─► Logs /aws/rds/instance/aws-workshop-dev-mysql/{error,slowquery}
Lambda               ─► metrics RetailHealth/dev HealthCheckOk, HealthCheckLatencyMs
AWS/EC2, AWS/RDS, custom metrics ─► 10 CloudWatch alarms ─► SNS aws-workshop-alerts ─► email
                                                         └► EC2 auto-recover (system check)
Dashboard aws-workshop-dev: one page for incidents.  Weekly GitHub Action: FinOps audit report.
```

| File | Contents |
|---|---|
| `bootstrap/alerts.tf` | SNS topic + email subscription + topic policy; budget alerts also go to the topic |
| `infra/logs.tf` | Log groups (all with 7-day retention), nginx 5xx metric filter |
| `infra/monitoring.tf` | 10 alarms (`for_each` over a map), EC2 auto-recover, dashboard |
| `infra/healthcheck.tf` + `infra/lambda/healthcheck.py` | Synthetic check Lambda (Python 3.13, arm64) |
| `infra/scheduler.tf` | Scheduler role (least privilege), office-hours schedules, health check schedule |
| `scripts/finops-audit.sh` + `.github/workflows/finops-audit.yml` | Read-only cost hygiene report |

## Alarms (10 = the CloudWatch free tier)
| Alarm | Why it exists |
|---|---|
| `healthcheck-failed` | The symptom users feel: `/readyz` (app + DB) fails from the internet, twice in a row |
| `nginx-5xx` | Users get errors even though the site is "up" |
| `rds-connections-high` (> 40, max ≈ 60) | **Cloud SQL connection-pool incident, AWS edition**: alert while there is still headroom |
| `rds-cpu-high`, `rds-freeable-memory-low`, `rds-free-storage-low` | Database saturation; storage autoscaling is off |
| `ec2-cpu-high`, `ec2-cpu-credits-low` | Host saturation; with `standard` credits, 0 credits = throttled to 10% |
| `ec2-system-check-failed` | AWS hardware problem → **auto-recover** to new hardware (same ID, IP, EIP, EBS) + email |
| `healthcheck-lambda-errors` | Watch the watcher: a broken checker otherwise looks like "all green" |

Design choices:
- **`treat_missing_data = notBreaching`** everywhere: at night the scheduler stops EC2/RDS and their metrics
  stop. The health-check Lambda also skips (publishes nothing) when the instance isn't running.
- **`ok_actions`** too: you get "resolved" emails and know when an incident is over.
- **Alarms are a map + `for_each`**: adding an alarm is 10 lines of data, not a new resource block.

## Why the SNS topic is in bootstrap
The repo is public. If the email were a Terraform variable of `infra`, it would have to be a CI secret, and it
would still end up in the saved plan artifact (downloadable by anyone with a GitHub account on a public repo).
Bootstrap is applied by an admin with a local, git-ignored `terraform.tfvars`, so the address never touches CI.
`infra` finds the topic with `data "aws_sns_topic"` by name — a common **cross-stack reference** pattern
(alternatives: `terraform_remote_state`, SSM parameters).

Ordering consequence: the bootstrap change must be applied **before** the infra PR can plan (the data source
must find the topic). Same as real teams: platform/foundation change first, consumers second.

After the first apply, AWS emails "AWS Notification - Subscription Confirmation" → **click Confirm**, or no
alert is ever delivered (status stays `PendingConfirmation`).

## Logs
- Docker's default log driver on the host is `awslogs` (set in `/etc/docker/daemon.json` from user_data), so
  `docker-compose.yml` stays unchanged and still works on a laptop. `mode: non-blocking` = if CloudWatch is
  slow, drop log lines instead of freezing the app. `docker logs` still works (dual logging).
- The instance role can only `CreateLogStream`/`PutLogEvents` in **its** log group; Terraform owns the group.
- RDS exports `error` + `slowquery` (slow query log was enabled in Phase 5, `long_query_time = 1`).
- **Every log group is created by Terraform with retention.** Services that create their own groups (RDS,
  Lambda) default to *Never expire* — pre-creating the group with the exact name avoids that hidden cost.

Logs Insights queries to try (CloudWatch → Logs Insights):
```
# slowest requests
filter ispresent(status) | sort rt desc | fields @timestamp, status, uri, rt | limit 20
# error rate per 5 minutes
filter ispresent(status) | stats count(*) as total, sum(status >= 500) as errors by bin(5m)
# health-check results (log group /aws/lambda/aws-workshop-dev-healthcheck)
filter ispresent(ok) | stats avg(latency_ms), min(ok) by bin(1h)
```

## Synthetic health check: why a Lambda
| Option | Problem here |
|---|---|
| Route 53 health check | Metrics only in **us-east-1**, which the sandbox SCP blocks |
| CloudWatch Synthetics canary | ~$0.0012/run → ~$10/month at 5 min |
| **Lambda + Scheduler** | ~8,600 invocations/month = free tier ✅ |

CI detail: `archive_file` builds the zip during `plan`. The apply job runs on another runner, so the
`terraform-apply` workflow uploads `infra/.build/` together with the saved plan.

## FinOps
**Office hours** (EventBridge Scheduler universal targets call `ec2:StopInstances` / `rds:StopDBInstance`
directly, no Lambda): running 14 h instead of 24 h saves ~40% of EC2 + RDS compute. Order matters: start the
DB first, stop the web host first. Set `office_hours.enabled = false` to keep everything on.

Side effects while asleep: the app deploy job fails (no running instance; re-run it later), RDS can't be
modified while stopped, and AWS auto-starts a stopped RDS after 7 days (the daily stop catches it).
Storage (EBS, RDS storage) and the EIP still cost money when stopped.

**Hidden cost found: T3 "unlimited" credit mode.** AWS launches T3 instances in `unlimited` mode by default:
if CPU stays above the baseline (10% for t3.micro) you pay $0.05 per vCPU-hour of surplus, silently. Set to
`standard` (`credit_specification`), plus the `ec2-cpu-credits-low` alarm. The audit script found it.

**`scripts/finops-audit.sh`** (weekly in Actions with the read-only user, or locally): unattached EBS, unassociated
EIPs, public IPv4 count, stopped instances, old snapshots, manual RDS snapshots, log groups without retention,
unlimited-credit instances, untagged ECR images, month-to-date cost per service. `STRICT=1` makes it fail on findings.

Cost of Phase 7 itself: ~$0.30/month (one custom metric from the metric filter + health check metrics) +
log ingestion (cents). Alarms, dashboard, Lambda, Scheduler, SNS email are within the free tier.

## Issues hit
- `[ -n "$line" ] && say ...` as the last command of a function under `set -e` made the audit script exit
  silently with code 1 (same trap as Phase 6). Use `if … then … fi`.
- `jq` isn't installed in Git Bash on Windows → the script uses only `--query` (JMESPath) + `awk`.

## Interview Q&A
- **Q: What do you alert on?**
  A: User-facing symptoms first (availability from outside, error rate, latency), then leading indicators of
  known failure modes (connection count vs. max, storage, credits). Every alert must be actionable; alert on
  recovery too; tune `treat_missing_data` so planned downtime doesn't page.
- **Q: You had a connection-pool exhaustion incident. How would you detect it on AWS?**
  A: Alarm on RDS `DatabaseConnections` well below `max_connections`, plus app-side pool metrics, plus
  `/readyz` that checks the DB. Fix side: right-size pools per instance × instance count, or RDS Proxy.
- **Q: How do you keep CloudWatch costs under control?**
  A: Retention on every log group (Terraform owns them), avoid high-cardinality custom metrics, metric filters
  instead of shipping to a third party for simple counts, and watch for "Never expire" groups.
- **Q: Cheapest way to cut a dev environment's bill?**
  A: Turn it off when nobody uses it (scheduler), delete orphans (EBS, EIPs, snapshots), right-size, avoid
  NAT Gateways in dev, and check defaults like T3 unlimited mode.
- **Q: How does a stack reference resources from another stack?**
  A: Data sources by name/tag, `terraform_remote_state`, or published values in SSM Parameter Store. Data
  sources keep stacks loosely coupled (no access to the other state file needed).
