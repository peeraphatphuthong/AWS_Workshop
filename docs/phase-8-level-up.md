# Phase 8 — Level up (modules, environments, ALB + ASG, Fargate)

Phase 8 is split into small PRs. Each one is shippable on its own.

| Step | What | Cost | Status |
|---|---|---|---|
| 8.1 | Refactor the flat `infra/` stack into modules with `moved` blocks (zero-change plan) | $0 | ✅ |
| 8.2 | Multi-environment layout (dev applied, prod plan-only) | $0 | ⬜ |
| 8.3 | ALB + Auto Scaling Group (stateless web tier) | ~+$0.50/day | ⬜ (needs approval) |
| 8.4 | ECS Fargate comparison | small | ⬜ |

## 8.1 Modules

```
modules/
├── network/        VPC, subnets (for_each), IGW, route tables, default SG/RT, security groups
├── database/       DB subnet + parameter group, RDS MySQL, app secret (write-only), RDS log groups
├── web/            instance role/profile, EC2 + EBS + EIP, image-tag parameter, user_data, container logs
└── observability/  alarms, dashboard, health-check Lambda, schedulers, nginx 5xx metric filter
infra/              root of the dev environment: providers, backend, variables, ECR, module wiring, moved.tf
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
