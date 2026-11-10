# Incident 2026-11-10 — scanner burst caused 40 s of 504s on the EC2 tier

| | |
|---|---|
| Date | 2026-11-10, 10:06:20–10:06:59 (Asia/Bangkok) = 03:06Z |
| Impact | 1,671 requests answered 504 by NGINX + 72 ALB 5xx (port 80, EC2 tier). Fargate (:8080) not targeted. |
| Detection | CloudWatch alarm `aws-workshop-dev-nginx-5xx` (ALARM 10:07, OK 10:12) → SNS email |
| Duration | ~40 s of errors; recovered by itself, no instance replaced |
| Severity | Low (dev), but the same pattern would be a real outage in production |

## Timeline (Bangkok)
| Time | Event |
|---|---|
| before 10:05 | normal: ~8 req/min (ALB health checks) |
| 10:05 | scanner starts: 233 req/min |
| 10:06 | **14,188 requests in one minute**, peak ~480 req/s, one client, 924 rotating User-Agents, probing `/admin.zip`, `/mysql_access.txt`, `/wp-admin/...`, `/manager/html` |
| 10:06:20–10:06:59 | NGINX: `upstream timed out (110) while connecting to upstream` → 504 (1,671 times) |
| 10:07–10:08 | scanner continues at 2–3k req/min; app keeps up, no errors |
| 10:12 | alarm back to OK |

## What happened
1. **One Node.js process fell behind.** 404s, normally ~0.5 ms, took 0.32 s on average: requests were queuing in
   the event loop. When it is busy, Node stops accepting connections; its listen backlog filled, new TCP
   connections from NGINX were not accepted within `proxy_connect_timeout 5s` → 504. The ALB also failed to connect
   to NGINX 70 times (`TargetConnectionErrorCount`).
2. **The dashboard amplified the load.** About 1,000 requests hit `/` (often `/?something`). Each one made 7 IMDS
   calls, a DB `INSERT` plus 2 queries, and appended/read the health log, so a page view was a write. The DB pool (5)
   was saturated, which pushed `/` latency to 1.45 s avg / 8.5 s max.
3. **Nothing limited a single client.** No rate limit at NGINX, no WAF.

Not the cause: EC2 CPU (5-minute average peaked at 15 %, which fits one core saturated for under a minute),
RDS (max 6 connections; alarm threshold 40), memory.

## What made it harder to investigate
- **The client IP was lost.** NGINX logged `$remote_addr`, which is the ALB node (`10.20.2.252`). The real client is
  only in `X-Forwarded-For`, which was not logged. ALB access logs are off.
- 5-minute EC2 metrics hide a 40-second spike.

## Fixes
| Fix | Where |
|---|---|
| Log the real client IP: `real_ip` trusts `X-Forwarded-For` only from inside the VPC (`10.0.0.0/8`), with `real_ip_recursive on` so a client-supplied XFF can't spoof it. Logs keep `peer` (ALB node) and raw `xff` too. | `app/nginx/nginx.conf` |
| Per-IP rate limit: 20 req/s, burst 40, excess → **429** at NGINX (never reaches Node). | `app/nginx/nginx.conf` |
| Status cache: `/` and `/api/status` share one result per 5 s (`STATUS_CACHE_MS`), single-flight so a burst of N concurrent requests triggers one refresh. IMDS is read once per process. | `app/src/cache.js`, `app/src/app.js` |
| Regression tests: 50 concurrent `/api/status` → 1 refresh; CI runs the real NGINX config in front of the image and expects 429s for a 100-request burst. | `app/test/`, `.github/workflows/app-ci.yml` |

## Not done (trade-offs)
- **AWS WAF** with a rate-based rule + AWS managed rule groups (known bad inputs, IP reputation) on the ALB:
  ~$5/month per web ACL + $1/rule + $0.60 per million requests. It would also protect the Fargate path (:8080),
  which has no NGINX in front. This is the production answer, and it scales to many-IP floods, which a per-IP limit
  at NGINX cannot stop.
- **ALB access logs** to S3 (cheap, but another bucket and lifecycle policy).
- **Node cluster / more instances**: a burst like this is over before an ASG can scale (minutes), so shedding load
  early (rate limit) beats adding capacity.

## Lessons
- An unauthenticated GET must be cheap and must not write. Cache or precompute anything expensive.
- Behind a load balancer, log the client IP from `X-Forwarded-For`, and trust it only from the load balancer.
- Shed excess load at the edge (WAF / proxy) before it reaches the single-threaded app.
- The 5xx alarm did its job: symptom-based alerting caught an incident no one was watching.
