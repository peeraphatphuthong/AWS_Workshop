# Phase 5 — Database (RDS MySQL 8.4, Secrets Manager, TLS, least-privilege app user)

## What was built
| Resource | Details |
|---|---|
| `aws_db_subnet_group.main` | private-a + private-b (RDS requires ≥ 2 AZs even for single-AZ) |
| `aws_db_parameter_group.mysql` | family `mysql8.4`: `require_secure_transport=1`, slow query log (>1 s) |
| `aws_db_instance.mysql` | MySQL **8.4** LTS, `db.t4g.micro` (Graviton), gp3 20 GB encrypted, private, single-AZ, 1-day backups, `manage_master_user_password` |
| `aws_secretsmanager_secret.db_app` | `/retail-health/dev/db/app` — app user credentials, written with `secret_string_wo` |
| `aws_iam_role_policy.web_db_secrets` | instance role may read the app secret and the RDS-managed master secret |
| `db-bootstrap` (on host) | creates/updates `retail_app` user with only `SELECT, INSERT, UPDATE, DELETE, CREATE, INDEX` on `retail.*`, `REQUIRE SSL` |
| `deploy-app` (on host) | pulls DB creds from Secrets Manager into a root-only `.env` at deploy time |
| App | verifies the RDS certificate (CA bundle baked into the image), writes a `store_checks` row per dashboard view |

```
EC2 (web SG) ──TLS 1.3, cert verified──► RDS MySQL 8.4 (db SG, private subnets, no internet route)
   │                                          ▲
   ├─ Secrets Manager: /retail-health/dev/db/app  (retail_app / generated password)
   └─ Secrets Manager: rds!db-...  (dbadmin — created & owned by RDS, used only by db-bootstrap)
```

## Secrets — three different patterns, on purpose
| Secret | How it's created | In Terraform state? |
|---|---|---|
| RDS master password | `manage_master_user_password = true` → RDS generates and stores it in Secrets Manager | **No** |
| App DB password | `ephemeral "random_password"` → `secret_string_wo` (write-only argument, TF ≥ 1.11) | **No** — plan shows `(write-only attribute)` |
| (anti-pattern, not used) | `resource "random_password"` + `secret_string` | Yes, plaintext in state |

Rotation of the app password: increase `db_app_password_version` → `terraform apply` writes a new secret value →
run `db-bootstrap` (ALTER USER) and `deploy-app` on the host (Phase 6 automates this through SSM Run Command).

## Why MySQL 8.4 and not 8.0?
`aws rds describe-db-major-engine-versions` shows 8.0 standard support ended **2026-07-31**; since 2026-08-01 it
runs on **RDS Extended Support**, billed per vCPU-hour on top of the instance price. 8.4 is the LTS line with
standard support until 2029-07-31. Checking engine lifecycle before choosing a version is part of the job.

## Defense in depth for the database
1. **Network**: private subnets, no route to the internet, `publicly_accessible = false`.
2. **Security group**: 3306 only from the web SG (SG reference, not CIDR).
3. **Transport**: `require_secure_transport=1` on the server + `REQUIRE SSL` on the user + client verifies the
   certificate with the RDS CA bundle (`rejectUnauthorized: true` / `--ssl-mode=VERIFY_IDENTITY`).
4. **Identity**: the app uses `retail_app` with schema-level grants, never the master user.
5. **Secrets**: no password in code, image, repo, or Terraform state; `.env` on the host is `umask 077`.
6. **At rest**: storage encrypted (KMS), backups/snapshots inherit encryption.

## Concepts
- **DB subnet group** = which subnets RDS may place the instance (and a Multi-AZ standby) in.
- **Parameter group** = MySQL server settings (`my.cnf`). Static parameters need a reboot; dynamic apply live.
  `name_prefix` + `create_before_destroy` lets a family change create the new group before detaching the old one.
- **Multi-AZ** (synchronous standby in another AZ, automatic failover ~60-120 s, DNS name stays the same) vs
  **Read replica** (asynchronous, for read scaling / DR, separate endpoint).
- **Endpoint is DNS**: apps must connect by hostname, never by IP — failover changes the IP behind the name.
- **Connection budget**: `max_connections` on a micro instance is small. Total = pool size × app instances
  (+ admin tools). Our pool is 5. RDS Proxy pools connections centrally when many clients/Lambdas connect.
- **Backups**: automated backups + point-in-time restore (within the retention window); a restore always creates a
  **new** instance.
- **Write-only arguments**: Terraform sends the value to the provider on apply but never persists it. Combined with
  `ephemeral` resources, secrets stay out of state and plan files entirely.

## Verification
```powershell
Invoke-RestMethod http://<eip>/api/status | Select-Object -ExpandProperty db
#   status ok, version 8.4.x, tls TLS_AES_*, totalChecks increments on every request
terraform output rds_endpoint             # private DNS, resolves only inside the VPC
Test-NetConnection <rds_endpoint> -Port 3306   # from a laptop: fails (private, no route) — as intended
```
Through SSM on the host:
```bash
sudo cat /opt/retail-health/.env | cut -d= -f1      # keys only, never print the values
sudo docker compose -f /opt/retail-health/docker-compose.yml logs app --tail 20
```

## Problems hit while rolling out (and what they teach)

### 1. Bootstrap killed by GitHub HTTP 504 (external dependency at boot)
The replaced instance never came up: `curl` of the Compose plugin from GitHub releases returned **504**, and
`set -e` aborted user_data. Adding `--retry 8` did not help — GitHub release downloads were failing for every
client (also from the laptop), not just transiently.
Fix: two sources, one checksum. Try GitHub, fall back to the identical binary in the `docker/compose-bin` image on
Docker Hub (verified: same sha256 `47737f42…`), then `sha256sum -c` regardless of source.
Lesson: every download at boot is a dependency on a third party's uptime. Production answer: bake tools into a
custom AMI (EC2 Image Builder / Packer) or mirror artifacts in your own S3/ECR.

### 2. `EACCES` reading the RDS CA bundle (non-root container)
`ADD <url>` created `/app/certs/...` readable only by root; the app runs as `node` → TLS setup failed.
Fix: explicit `chmod` in the Dockerfile + a CI smoke-test step that reads the file **as the container user**, so the
regression can't come back silently.
Lesson: running as non-root is right, but test file permissions as that user.

### 3. Rolling out a fixed image WITHOUT touching infrastructure
The fix needed no Terraform at all — exactly the deploy model from Phase 4:
```powershell
gh workflow run app-ci --ref <branch>                                        # build, scan, push :<sha>
aws ssm put-parameter --name /retail-health/dev/app/image-tag --value <sha> --overwrite
aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript `
  --parameters 'commands=["/usr/local/bin/deploy-app"]'                     # pull + restart + health check
```
Result: `OK: ...retail-health:b574332... is healthy`, DB card green. Phase 6 turns these three commands into the
pipeline.

### 4. EBS data survived three instance replacements
`/api/status` after the replacements still showed health-log lines written by the **first** instance
(`totalWrites: 12`, entries from 09:31). The `blkid || mkfs` guard did its job: re-attached volumes are mounted,
never reformatted.

## Interview Q&A
- **Q: How do you manage database passwords with Terraform?**
  A: Let RDS manage the master password in Secrets Manager (`manage_master_user_password`). For other secrets use
  ephemeral resources + write-only arguments so nothing lands in state; apps read secrets at runtime via IAM.
  If a secret must be in state, encrypt and lock down the state backend.
- **Q: The app gets "Too many connections" on RDS. What do you do?**
  A: Short term: find who holds connections (`SHOW PROCESSLIST`), lower/size app pools, fix leaks, add retries with
  backoff. Medium term: right-size the instance class (max_connections scales with memory), add RDS Proxy, alarm on
  `DatabaseConnections` (Phase 7). This mirrors the Cloud SQL connection-pool incident from previous work.
- **Q: How do you make sure DB traffic is encrypted?**
  A: Server-side `require_secure_transport`, per-user `REQUIRE SSL`, client verifies the CA (RDS bundle) and
  hostname. Check `Ssl_cipher` in the session status.
- **Q: Single-AZ vs Multi-AZ vs read replica?**
  A: Single-AZ: cheapest, AZ outage = downtime. Multi-AZ: HA with synchronous standby and automatic failover, ~2× cost.
  Read replica: async copy for read scaling or cross-region DR, can be promoted.
- **Q: Why does a DB subnet group need two AZs if the instance is single-AZ?**
  A: RDS requires it so the instance can be moved/restored or converted to Multi-AZ without network changes.
- **Q: How would you migrate an on-prem MySQL to RDS with minimal downtime?**
  A: AWS DMS (full load + CDC) or native replication into RDS, validate, then cut over (stop writes, wait for lag 0,
  switch the app endpoint). Snapshot/dump-restore for small DBs where downtime is acceptable.

## Cost
`db.t4g.micro` single-AZ + 20 GB gp3 ≈ **$0.60–0.70/day** in ap-southeast-2. Whole stack now ≈ $1.15/day.
To pause: `aws rds stop-db-instance --db-instance-identifier aws-workshop-dev-mysql` (auto-restarts after 7 days),
or `terraform destroy` the stack (data is lost because `skip_final_snapshot = true`).
