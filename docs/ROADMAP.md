# Roadmap

Every phase is delivered the way a real team would: feature branch → Pull Request → CI checks → review → merge.
Each phase ends with a `docs/phase-N-*.md` note (concepts, commands, interview Q&A) and a teardown step.

| # | Phase | Deliverables | Key concepts | Status |
|---|---|---|---|---|
| 0 | Setup | Tools installed, AWS/GitHub auth, repo skeleton, first push | IAM basics, regions, billing | ✅ Done |
| 1 | Bootstrap | S3 state bucket, AWS Budget, CI IAM user (OIDC blocked by SCP) | Remote state, locking, SCPs, least privilege | ✅ Done |
| 2 | Network | VPC, public/private subnets in 2 AZs, IGW, route tables, security groups | `for_each`, `locals`, `cidrsubnet`, SG references | ✅ Done |
| 3 | App + ECR | Node.js dashboard app, Dockerfile, NGINX, build & push to ECR in Actions | Container registry, image tagging | ✅ Done |
| 4 | Compute | EC2 + EIP + EBS (same AZ), user_data mount, instance profile, SSM | Zonal resources, dependency graph, `-replace`, `-target` | ✅ Done |
| 5 | Database | RDS MySQL 8.4 (private, TLS), Secrets Manager, least-privilege app user | Secret handling (write-only args), defense in depth | ✅ Done |
| 6 | Full CI/CD | PR: fmt/validate/tflint/Trivy/plan comment · main: gated apply · app deploy via SSM | GitOps for IaC, environments & approvals | ✅ Done |
| 7 | Observability & FinOps | CloudWatch alarms + SNS, logs, dashboard, synthetic check, scheduled stop/start, orphaned-resource audit | Alerting, hidden costs | ✅ Done |
| 8 | Level up (optional) | ALB + Auto Scaling Group, modules, dev/prod split, ECS Fargate comparison | HA, reuse, multi-env | ✅ Done (8.1 modules, 8.2 envs, 8.3 ALB+ASG, 8.4 Fargate) |

## GCP → AWS mental map (from previous experience)

| GCP | AWS |
|---|---|
| Workload Identity Federation | IAM OIDC provider + `AssumeRoleWithWebIdentity` |
| Artifact Registry | ECR |
| Compute Engine + Persistent Disk | EC2 + EBS |
| Cloud SQL | RDS |
| Cloud Run | ECS Fargate / App Runner |
| GKE | EKS |
| Cloud Monitoring / Logging | CloudWatch Metrics / Logs |
| Secret Manager | Secrets Manager / SSM Parameter Store |
| GCS (Terraform backend) | S3 |
