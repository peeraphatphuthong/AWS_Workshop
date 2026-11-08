# Phase 1 — Bootstrap (Budget, Remote State, CI Identity)

## What was built (`bootstrap/`)
| Resource | Why |
|---|---|
| `aws_budgets_budget.monthly` | $10/month budget, email at 50% / 80% actual and 100% forecast. Guardrail first. |
| `aws_s3_bucket.tfstate` + versioning, SSE, public-access-block, ownership controls, lifecycle, TLS-only policy | Remote state for every stack. `prevent_destroy` protects it. |
| `aws_iam_user.github_ci` + `aws_iam_policy.github_ci` | Identity for GitHub Actions (see "Why not OIDC?"). |

State key layout in the bucket:
```
aws-workshop-tfstate-525091405764-ap-southeast-2/
├── bootstrap/terraform.tfstate     # this stack (migrated from local)
└── infra/terraform.tfstate         # main stack (Phase 2+)
```

## Step by step (what was actually run)
```powershell
cd bootstrap
copy terraform.tfvars.example terraform.tfvars   # fill in budget email (file is git-ignored)
terraform init
terraform plan -out=tfplan        # 11 to add
terraform apply tfplan

# Chicken-and-egg solved: add backend.tf, then move local state into the bucket it just created
terraform init -migrate-state -force-copy
terraform plan -detailed-exitcode # exit 0 = no drift after migration
Remove-Item terraform.tfstate*    # local copy no longer needed

# Create CI key and store it as GitHub Environment secrets (never printed, never in state)
powershell -ExecutionPolicy Bypass -File ..\scripts\rotate-ci-key.ps1
```

## Real-world constraint hit: SCP denies OIDC
`iam:ListOpenIDConnectProviders` returned **AccessDenied ... explicit deny in a service control policy**.
- **SCP (Service Control Policy)** is set at the AWS Organization level. It is a *ceiling*: even `AdministratorAccess`
  inside the account cannot exceed it. An explicit Deny in an SCP always wins.
- IAM evaluation order: explicit Deny (anywhere) → SCP allows? → permission boundary allows? → identity/resource
  policy allows? → otherwise implicit deny.

### Why not OIDC? / What we did instead
| | OIDC role (preferred) | IAM user + key (used here) |
|---|---|---|
| Credential lifetime | ~1 hour, per job | Until rotated |
| Leak impact | Token useless after expiry | Usable until key deleted |
| Scope to repo/branch | Trust policy `sub` condition (`repo:owner/name:ref:refs/heads/main`) | Not possible — anyone with the secret |
| Setup | OIDC provider + role | User + policy + key rotation |

Mitigations applied to the IAM user:
1. **Region lock** — every non-IAM action has `aws:RequestedRegion = ap-southeast-2`.
2. **IAM path boundary** — CI can only create/modify roles, instance profiles and policies under `/aws-workshop/`,
   and `iam:PassRole` only for those. It cannot create an admin role for itself elsewhere.
3. **Key never in Terraform state** — created by script, sent directly to GitHub.
4. **Environment secret** (`aws-sandbox`), not repo secret — later we add protection rules (required reviewer,
   branch restriction) so only approved jobs on `main` get the key.
5. **Rotation** — `scripts/rotate-ci-key.ps1` creates a new key, updates secrets, deletes the old key.
6. **Proof** — `.github/workflows/aws-access-check.yml` asserts both positive (state bucket, EC2 in region) and
   negative (us-east-1 denied, IAM outside path denied) permissions.

Known gap: the policy uses service wildcards (`ec2:*`, `rds:*`...). Next step in a real team: run the pipeline for a
while, then use **IAM Access Analyzer policy generation** (from CloudTrail) to produce an exact action list.

## Concepts
- **Remote state + locking**: local state can't be shared and is lost with the laptop. S3 backend shares it; the
  lock (`use_lockfile = true` writes `terraform.tfstate.tflock` next to the state with a conditional PUT) stops two
  applies from running at the same time and corrupting state. Before Terraform 1.10 this needed a DynamoDB table.
- **Bootstrap problem**: the bucket that stores state must exist before any backend can use it. Pattern: create it
  with local state → add backend block → `init -migrate-state`.
- **`prevent_destroy`**: Terraform errors out on any plan that would destroy the resource. To really delete it you
  must remove the flag first — a deliberate two-step.
- **`default_tags`**: provider-level tags on every resource → enables Cost Explorer grouping by `Project`.
- **Bucket names are global**: hence `<project>-tfstate-<account>-<region>`.

## Interview Q&A
- **Q: How do you store Terraform state for a team?**
  A: Remote backend (S3) with versioning, encryption, public access blocked, TLS-only bucket policy, and locking
  (S3 native lockfile or DynamoDB). Separate state per stack/environment to limit blast radius. Restrict who can read
  state since it can contain secrets.
- **Q: Two engineers run `terraform apply` at the same time. What happens?**
  A: The second one fails to acquire the lock and waits/errors. If a lock is left behind by a crashed run, use
  `terraform force-unlock <LOCK_ID>` only after confirming nothing is running.
- **Q: Your admin role gets AccessDenied. Why could that be?**
  A: An SCP explicit deny (org level), a permission boundary, a resource policy deny (e.g. bucket policy), or a
  session policy. The error message tells which (here: "explicit deny in a service control policy").
- **Q: How would you give GitHub Actions AWS access?**
  A: OIDC federation with a role scoped by `sub` to repo + branch/environment. If OIDC is blocked (like here), a
  least-privilege IAM user with region/path conditions, environment-scoped secrets, and automated rotation.
- **Q: How do you protect the state bucket from accidental deletion?**
  A: `prevent_destroy`, versioning (recover previous state), optionally MFA delete / Object Lock, and limiting
  `s3:DeleteBucket` via IAM.

## Teardown
Bootstrap resources cost ~$0 (S3 with a few KB, IAM and Budgets are free), so they stay for the whole project.
To remove everything at the very end: remove `prevent_destroy`, empty the bucket (all versions), migrate state back
to local (`terraform init -migrate-state` after deleting `backend.tf`), then `terraform destroy`.
