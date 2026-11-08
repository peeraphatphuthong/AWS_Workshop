# Phase 6 — CI/CD (PR plan, gated apply, continuous deployment with rollback)

From this phase on, **nobody applies Terraform or deploys from a laptop**. Every change goes:
branch → PR (checks + plan comment) → review → merge → pipeline.

## Identities and environments
| GitHub environment | Allowed branches | Approval | AWS IAM user | Permissions |
|---|---|---|---|---|
| `aws-plan` | any | – | `aws-workshop-github-plan` | `ReadOnlyAccess` + create/delete `*.tflock` in the state bucket; explicit deny on any other state write |
| `aws-dev` | `main` | – | `aws-workshop-github-ci` | project services in ap-southeast-2, IAM only under `/aws-workshop/` |
| `aws-dev-infra` | `main` | required reviewer | `aws-workshop-github-ci` | same as above |

Why two users: a pull request runs code from a branch. With only one (write) key, any branch could
`terraform apply` or delete resources from a workflow file. Now PR jobs only ever hold a read-only key,
and the write key is released only to jobs running on `main` (and, for infra, only after a human approves).
`aws-access-check` proves it on every bootstrap PR: the plan user can read, but cannot overwrite state,
read secret values, or create resources.

Setup scripts: `scripts/setup-github-environments.ps1` (environments, branch policies, reviewers — no secrets)
and `scripts/rotate-ci-key.ps1 -UserName <user> -Environments a,b` (keys straight into environment secrets).

## Pipelines
```
Pull request ─┬─ terraform-ci ── static (fmt, validate, tflint+aws ruleset)
              │                ├─ security (Trivy IaC scan, blocking on HIGH/CRITICAL)
              │                └─ plan (aws-plan) ──► PR comment "Terraform plan — infra — 📝 Changes"
              ├─ app-ci ─────── test → build → smoke test → Trivy image scan
              └─ aws-access-check (bootstrap changes)

Merge to main ┬─ terraform-apply ── plan (aws-plan, saved + job summary)
              │                     └─► apply (aws-dev-infra) ⏸ waits for approval ─► applies THAT plan
              └─ app-ci ─── … → push (aws-dev) → deploy (aws-dev)
                                  record previous tag → put-parameter → SSM deploy-app
                                  → smoke test public URL (gitSha + db + ebs) → ✅
                                  └─ on failure: restore previous tag + redeploy (rollback) → ❌
```

### Design notes
- **Plan comment is updated, not duplicated** (hidden marker `<!-- terraform-plan:infra -->`).
- **Saved plan + approval**: the reviewer approves the exact plan shown in the summary. If someone else changed
  state in between, Terraform rejects the saved plan as stale instead of applying something unreviewed.
- **`concurrency: terraform-apply-infra`, `cancel-in-progress: false`**: applies are serialized and never killed
  halfway (a killed apply can leave a stale lock and partial changes).
- **Deploy by tag, not by instance ID**: the job finds the running instance tagged `aws-workshop-dev-web`, so
  instance replacements (Phase 4/5) don't break the pipeline.
- **Rollback is automatic** and uses the same mechanism as deploy (Parameter Store + `deploy-app`), so it is
  tested every day, not only during an incident.
- **What triggers infra applies**: `infra/**` *and* `app/docker-compose.yml` / `app/nginx/**`, because those files
  are embedded in EC2 user_data (changing them replaces the instance).

## Security scanning: risk acceptance instead of disabling checks
The first Trivy IaC run found 3 issues:

| ID | Finding | Decision |
|---|---|---|
| AWS-0132 | State bucket not encrypted with a customer-managed KMS key | Accepted: SSE-S3 + IAM + TLS-only policy; CMK for production |
| AWS-0104 ×2 | Web SG egress 80/443 to 0.0.0.0/0 | Accepted: needed for ECR/SSM/packages without NAT/endpoints; endpoints + egress allow-list for production |

`.trivyignore.yaml` entries are **path-scoped**, have a **statement** and an **`expired_at`** date, so the
acceptance is reviewed in a PR and automatically resurfaces in 6 months. The scan stays blocking for anything new.

## Issues hit
- **Windows PowerShell 5.1 + UTF-8 without BOM**: an em dash inside a string in a `.ps1` file was read as ANSI
  garbage → parse error. Keep PowerShell scripts ASCII-only (or save with BOM).
- **PowerShell strips inner double quotes** when passing arguments to native programs (`gh api --jq '... ","'`
  broke). Avoid double quotes inside such arguments or use files.
- **`[ cond ] && cmd` as the last command of a bash block under `set -e`** makes the step fail when the condition is
  false. Use `if … then … fi` in CI scripts.

## Day-to-day workflow (what you do now)
1. `git switch -c feat/x`, change code, push, open a PR.
2. Read the PR checks and the plan comment. Fix until green.
3. Merge (squash).
4. App change → deployed to dev automatically in ~3 min, URL in the deployment's environment link.
5. Infra change → open the **terraform-apply** run → review the plan summary → **Review deployments → Approve**.

## Interview Q&A
- **Q: How do you run Terraform in CI/CD safely?**
  A: Plan on PR with read-only credentials, post the plan for review, apply only from the main branch with a
  separate write identity behind an approval gate, apply the saved plan, serialize applies, keep state remote with
  locking, and scan IaC (tflint/Trivy/Checkov) before merge.
- **Q: How do you roll back a bad deployment?**
  A: Deploy immutable, SHA-tagged images; record the previous version before switching; health/smoke-check after
  deploy; on failure switch the pointer back and redeploy. Infra rollbacks are a revert PR (Terraform has no
  "undo").
- **Q: A security scanner flags something you need. What do you do?**
  A: Fix it if reasonable; otherwise document a scoped, time-boxed exception with the reason and a compensating
  control, reviewed like code. Never disable the scanner globally.
- **Q: Why not let PR pipelines use the deploy credentials?**
  A: PR code is untrusted until reviewed; a modified workflow could exfiltrate or misuse write credentials.
  Separate read-only identity for PRs, write identity only for protected branches/environments.
- **Q: GitHub Environments — what do they give you?**
  A: Scoped secrets/variables, required reviewers, wait timers, and branch restrictions per environment, plus a
  deployment history with URLs.
