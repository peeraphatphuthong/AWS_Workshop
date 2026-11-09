# Phase 8 — Level up (modules, environments, ALB + ASG, Fargate)

Phase 8 is split into small PRs. Each one is shippable on its own.

| Step | What | Cost | Status |
|---|---|---|---|
| 8.1 | Refactor the flat `infra/` stack into modules with `moved` blocks (zero-change plan) | $0 | ✅ |
| 8.2 | Multi-environment layout (dev applied, prod plan-only) | $0 | ✅ |
| 8.3 | ALB + Auto Scaling Group (stateless web tier) | ~+$0.50/day | ⬜ (needs approval) |
| 8.4 | ECS Fargate comparison | small | ⬜ |

## 8.1 Modules

```
modules/
├── network/        VPC, subnets (for_each), IGW, route tables, default SG/RT, security groups
├── database/       DB subnet + parameter group, RDS MySQL, app secret (write-only), RDS log groups
├── web/            instance role/profile, EC2 + EBS + EIP, image-tag parameter, user_data, container logs
└── observability/  alarms, dashboard, health-check Lambda, schedulers, nginx 5xx metric filter
infra/              (8.1) root of the dev environment -> moved to envs/dev in 8.2
```

Dependency flow (all through inputs/outputs, no module reaches into another):
```
network ──subnets, SG IDs──► database ──secret ARNs──► web ──instance, EIP, log group──► observability
```

### Module design rules used
- **One concern per module**, interface = `variables.tf` (inputs) + `outputs.tf` (what others may use).
- **No provider blocks inside modules**: providers (region, `default_tags`) are configured once in the root and
  inherited. Modules only declare `required_providers`.
- **Files that belong to the app stay outside modules**: the root reads `app/docker-compose.yml` and `nginx.conf`
  and passes the content in, so the web module doesn't depend on repository layout.
- **ECR stays in the root**: a registry is shared by all environments (images are promoted, not rebuilt).

### Cross-module ordering without `depends_on` on modules
Two explicit dependencies of the flat stack crossed module boundaries:

| Before (flat) | After (modules) |
|---|---|
| `aws_eip.web` `depends_on = [aws_internet_gateway.main]` | `network` output `public_subnets` has `depends_on = [IGW, default route]`; EC2 → EIP use that subnet |
| `aws_instance.web` `depends_on = [aws_secretsmanager_secret_version.db_app]` | `database` output `app_secret_arn` has `depends_on = [secret version]`; the instance uses that ARN |

Why not `module "web" { depends_on = [module.network] }`? Module-level `depends_on` makes **every data source in the
module wait until apply** ("known after apply"), so plans become noisy and can show false changes. Output-level
`depends_on` keeps the dependency precise.

### `moved` blocks: refactoring without destroying anything
Moving `aws_vpc.main` into `module.network` changes its **address** in state. Without help, Terraform plans
"destroy `aws_vpc.main`, create `module.network.aws_vpc.main`" (for every resource: VPC, EC2, RDS = outage + data loss).
```hcl
moved {
  from = aws_vpc.main
  to   = module.network.aws_vpc.main
}
```
`infra/moved.tf` has 49 blocks (generated from the resource list); `for_each` resources move with all their keys.
Result of `terraform plan`:
```
Plan: 0 to add, 0 to change, 0 to destroy.      (67 resource instances "has moved to")
```
Alternative before Terraform 1.1: `terraform state mv` for each address (imperative, not reviewed in a PR, easy to
get wrong). `moved` blocks are code: reviewed, repeatable for every copy of the state, and visible in the plan.

### Other details
- Lambda zip `output_path` uses `${path.root}/.build/...` so it still lands in `infra/.build/`, which the apply
  workflow uploads with the saved plan.
- CI: `modules/**` now triggers `terraform-ci` and `terraform-apply`; fmt also checks `modules/`; tflint inspects
  local modules (`call_module_type = "local"` in `.tflint.hcl`); the Trivy exception path moved to
  `modules/network/security_groups.tf`.

## 8.2 Environments: directory per environment

```
envs/
├── dev/    backend key envs/dev/terraform.tfstate   applied by CI (approval)   owns the shared ECR repo
└── prod/   backend key envs/prod/terraform.tfstate  plan-only (PR comment)     reads ECR with a data source
```
Each environment is a **thin root**: one `locals` block with the settings, then the same four modules.
`diff envs/dev/main.tf envs/prod/main.tf` is the whole difference between environments:

| Setting | dev | prod |
|---|---|---|
| VPC CIDR | 10.20.0.0/16 | 10.40.0.0/16 (non-overlapping → peering/TGW possible later) |
| AZs | 2 | 3 |
| Web instance / data volume | t3.micro / 10 GB | t3.small / 20 GB |
| RDS | db.t4g.micro, single-AZ, 1-day backups | db.t4g.small, **Multi-AZ**, 7-day backups |
| Delete protection | off, no final snapshot | **deletion_protection**, **final snapshot**, changes wait for the maintenance window |
| Log retention | 7 days | 30 days |
| Office-hours shutdown | enabled | schedules created but **disabled** (24/7) |

New database-module inputs (defaults = previous dev behaviour, so dev's plan stayed "No changes"):
`multi_az`, `backup_retention_days`, `deletion_protection`, `skip_final_snapshot` (+ `final_snapshot_identifier`),
`apply_immediately`.

### Why directory-per-environment (and not workspaces or one root + tfvars)?
| Option | Pros | Cons |
|---|---|---|
| **Directory per env** (chosen) | Explicit; each env has its own backend, providers, approvals; envs may differ structurally (prod has no ECR resource) | Some duplication in the thin roots |
| One root + `-var-file` per env + partial backend config | DRY; envs can't drift structurally | Every env must have the same resources; easy to apply the wrong var-file to the wrong backend |
| Terraform workspaces | Built-in, one backend | Same code + same credentials for all envs; the current workspace is invisible in code (classic "applied to prod by accident") |

### CI per environment
- `terraform-ci` runs **plan for each env** (matrix `dev`, `prod`) and posts **one comment per env**
  (`<!-- terraform-plan:dev -->`, `<!-- terraform-plan:prod -->`). The prod comment says it is plan-only.
- `terraform-apply` applies **only `envs/dev`**. A real prod rollout would add an `aws-prod-infra` environment
  (two reviewers, prod-only credentials in a separate AWS account) and promote the same commit after dev.
- A change in `modules/**` now shows its effect on **both** environments in the same PR.

### State migration (`infra/terraform.tfstate` → `envs/dev/terraform.tfstate`)
Moving the root directory doesn't move state; the backend **key** decides where state lives. Steps (admin, local):
```bash
cd envs/dev
terraform init -reconfigure -backend-config="key=infra/terraform.tfstate"   # 1. old key: plan = No changes
terraform init -migrate-state -force-copy -backend-config="key=envs/dev/terraform.tfstate"  # 2. copy
terraform plan -detailed-exitcode                                           # 3. new key: exit 0
```
⚠️ Gotcha hit: step 2 **without** `-backend-config` silently did nothing. Terraform remembers `-backend-config`
values from the previous `init` (in `.terraform/terraform.tfstate`), so the key was still `infra/...` and the plan
"passed" against the old state. Always check `.terraform/terraform.tfstate` (or the S3 listing) after a migration.
Done right before merging (no other apply in between), so the copy can't go stale. The old object stays in the
versioned bucket as a backup and is deleted after the merge.

## Interview Q&A (8.2)
- **Q: How do you structure Terraform for multiple environments?**
  A: Reusable modules + one thin root per environment with its own backend/state and credentials; differences
  are explicit values in each root. Promote the same commit/image from dev to prod; separate AWS accounts for prod.
- **Q: Workspaces vs directories?**
  A: Workspaces share code, backend and credentials and hide which env you're in — fine for short-lived copies
  (feature envs), risky for prod. Directories (or Terragrunt) give separate state, credentials and approvals.
- **Q: How do you move state when you rename/move a root?**
  A: Change the backend key and `terraform init -migrate-state` (or `terraform state pull/push`), verify with a
  zero-change plan, make sure nobody applies during the move, keep the old object as a backup.

## Verified before 8.1 (office-hours scheduler, Phase 7 follow-up)
- EC2 stopped 22:00 and started 08:00 (Asia/Bangkok) — app uptime matched.
- RDS events: `DB instance stopped` 22:10, `DB instance started` 07:30. Scheduler `TargetErrorCount` = 0, so the
  universal-target input `DbInstanceIdentifier` is correct.

## Interview Q&A
- **Q: How do you refactor Terraform into modules without recreating resources?**
  A: `moved` blocks (or `terraform state mv`), then confirm the plan shows only moves — 0 add/destroy — before merging.
- **Q: What makes a good Terraform module?**
  A: One responsibility, small explicit interface (typed variables with validation, minimal outputs), no provider
  configuration inside, no hard-coded environment values, documented, versioned when shared across repos.
- **Q: Why avoid `depends_on` on a whole module?**
  A: It defers all data sources in that module to apply time and creates over-broad ordering; prefer passing
  outputs (optionally with output-level `depends_on`) so dependencies stay precise.
