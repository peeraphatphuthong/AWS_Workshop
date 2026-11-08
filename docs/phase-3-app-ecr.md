# Phase 3 — Application, Container Image & ECR

## What was built
| Path | Content |
|---|---|
| `app/src/` | Node.js 24 + Express 5 "Retail Store Health" app: EC2 metadata (IMDSv2), EBS write/read + free space, RDS connectivity |
| `app/test/` | 6 tests with the built-in `node:test` runner (no extra dev deps) |
| `app/Dockerfile` | Multi-stage, prod deps only, npm removed, non-root user, HEALTHCHECK, exec-form CMD |
| `app/nginx/nginx.conf` | Reverse proxy: JSON access logs, gzip, security headers, `/nginx-health`, keepalive upstream |
| `app/docker-compose.yml` | `nginx` (port 80) → `app` (internal 3000), read-only root FS, `no-new-privileges`, EBS bind mount |
| `infra/ecr.tf` | ECR repo `aws-workshop/retail-health`: IMMUTABLE tags, scan on push, lifecycle (untagged 1 day, keep 10) |
| `.github/workflows/app-ci.yml` | PR: test → build → smoke test → Trivy. main: + push to ECR tagged with git SHA |

## Endpoints
| Path | Purpose |
|---|---|
| `/` | HTML dashboard |
| `/api/status` | Same data as JSON |
| `/healthz` | **Liveness** — process is up. Never checks dependencies. |
| `/readyz` | **Readiness** — EBS writable and (if configured) DB reachable; 503 otherwise |
| `/nginx-health` | Served by NGINX itself |

## Pipeline flow
```
pull_request ──► test ──► build-scan (build, smoke test, Trivy)                        no AWS access
push to main ──► test ──► build-scan ──► push (env: aws-sandbox) ──► ECR :<git-sha>
```
- **Build once per commit, tag by SHA**: the image that passed tests is identified exactly; deploy and rollback
  refer to `:<sha>`, never `:latest`.
- **IMMUTABLE tags** in ECR enforce that — re-pushing an existing tag fails.
- **Secrets only where needed**: only the `push` job uses the `aws-sandbox` environment; PR jobs never see AWS keys.
- **Layer cache** (`type=gha`) makes the second build in `push` take seconds.

## Run locally (no Docker needed)
```powershell
cd app
npm ci
npm test
$env:IMDS_DISABLED="true"; $env:DATA_DIR="$PWD\.data"; npm start   # http://localhost:3000
```
With Docker: `docker compose up --build` → http://localhost

## Concepts
- **Multi-stage build**: the final image doesn't contain build tools or dev dependencies → smaller, fewer CVEs.
- **Why remove npm from the runtime image?** It's only needed to install packages; its bundled dependencies are a
  regular source of scanner findings. Less software = less attack surface.
- **Non-root + read-only root FS + no-new-privileges**: if the app is compromised, the attacker can't write to the
  filesystem (except `/tmp` and `/data`) or escalate privileges.
- **Exec-form CMD (`["node", ...]`)**: node runs as PID 1 and receives SIGTERM from `docker stop`; shell form wraps it
  in `/bin/sh -c`, which swallows signals → hard kill after 10 s, dropped requests.
- **IMDSv2**: metadata requires a session token obtained with PUT. It blocks most SSRF credential theft. From a
  container (bridge network) the PUT response must cross one extra hop, so the instance needs
  `http_put_response_hop_limit = 2` (set in Phase 4).
- **Liveness vs readiness**: if liveness depended on the DB, a DB outage would make the orchestrator restart every
  healthy app container (cascading failure). Readiness removes the instance from the load balancer instead.
- **Connection pool sizing**: `connectionLimit: 5` per container. Total connections = pool × instances; must stay
  under the DB's `max_connections` (small for `db.t3.micro`). Directly related to the connection-pool exhaustion
  incident on Cloud SQL from previous experience.
- **ECR auth**: `aws ecr get-login-password` / `amazon-ecr-login` gives a Docker login token valid for 12 hours.
  On EC2, the instance role + the same call is used to pull (Phase 4).

## GCP ↔ AWS
| GCP (previous experience) | AWS (here) |
|---|---|
| Artifact Registry | ECR |
| `gcloud auth configure-docker` | `aws ecr get-login-password \| docker login` / `amazon-ecr-login` |
| Container Analysis scanning | ECR basic / enhanced (Inspector) scanning |

## Interview Q&A
- **Q: How do you tag images and why not `latest`?**
  A: Git SHA (optionally plus semver). `latest` is mutable and ambiguous — you can't tell what's running or roll back
  precisely. Use immutable tags in the registry.
- **Q: How do you keep container images secure?**
  A: Minimal base, multi-stage, non-root, no secrets in layers, pin versions, scan in CI (Trivy) and in the registry
  (ECR scan), fail on fixable HIGH/CRITICAL, rebuild regularly to pick up base image patches.
- **Q: What's the difference between liveness and readiness probes?**
  A: Liveness → restart if the process is stuck. Readiness → stop sending traffic until dependencies are OK. Don't
  put dependency checks in liveness.
- **Q: How do you control registry costs?**
  A: Lifecycle policies (expire untagged, keep last N), small images, one repo per service.
- **Q: How does an EC2 instance pull from a private ECR repo without credentials?**
  A: Instance profile role with `AmazonEC2ContainerRegistryReadOnly`; the SDK/CLI gets temporary credentials from
  IMDS, then `ecr get-login-password`.

## Cost
ECR: $0.10/GB-month — one ~60 MB image ≈ $0.006/month. The lifecycle policy caps it at 10 images.
