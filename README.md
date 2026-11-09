# AWS_Workshop — Retail Store Health Platform on AWS with Terraform

A hands-on, production-style project for learning **AWS** and **Terraform** end to end:
infrastructure as code, GitOps-style CI/CD with GitHub Actions, a containerized web app,
a managed database, monitoring, and cost control (FinOps).

> Status: **Phase 8 — Level up (in progress)**: Terraform modules, per-environment roots (`envs/dev` applied, `envs/prod` plan-only) on top of Phase 7 observability & FinOps (`terraform -chdir=envs/dev output web_url`) (see [docs/ROADMAP.md](docs/ROADMAP.md))

## Target architecture

```
GitHub (PR → CI → merge → CD)
   │  PR jobs: read-only IAM user · main jobs: deploy IAM user (+ approval for terraform apply)
   │  (OIDC is the preferred design but is denied by this sandbox's SCP — see docs/phase-1-bootstrap.md)
   ▼
AWS (ap-southeast-2, Sydney)
 ├─ S3              Terraform remote state (+ native lockfile)
 ├─ ECR             Docker images of the app
 └─ VPC (2 AZs)
     ├─ Public subnet   EC2 t3.micro + Elastic IP + EBS gp3
     │                  Docker: NGINX reverse proxy → Node.js app
     │                  Access via SSM Session Manager (no SSH port 22)
     └─ Private subnets RDS MySQL 8.4 db.t4g.micro (TLS only, creds in Secrets Manager)
 CloudWatch Alarms → SNS email · AWS Budgets · EventBridge Scheduler (stop off-hours)
```

## Repository layout (grows phase by phase)

```
.
├── bootstrap/        # Phase 1: budget, state bucket, CI identity (run locally by an admin)
├── envs/
│   ├── dev/          # root of the dev environment (state key envs/dev/...): settings + module wiring
│   └── prod/         # root of the prod environment: plan-only in this workshop
├── modules/          # Phase 8: network, database, web, observability
├── app/              # Phase 3: Node.js app, Dockerfile, NGINX config
├── scripts/          # FinOps / ops helper scripts
├── docs/             # Roadmap + per-phase notes and interview Q&A
└── .github/workflows # CI/CD pipelines
```

## Tooling

| Tool | Version used |
|---|---|
| Terraform | 1.17.x |
| AWS CLI | 2.39.x |
| GitHub CLI | 2.103.x |

## Cost guardrails

- AWS Budget alert before anything else is created.
- Smallest instance sizes (t3.micro / db.t3.micro, single-AZ RDS), no NAT Gateway.
- `terraform destroy` (or scheduled stop) at the end of every working session.
