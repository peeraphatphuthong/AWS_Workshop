# Phase 0 — Setup

## What was done
1. Installed tooling on Windows with `winget`: Git, AWS CLI v2, Terraform, GitHub CLI.
2. Set the default region: `aws configure set region ap-southeast-1`.
3. Authenticated:
   - AWS: `aws login` (browser sign-in with console credentials → short-lived credentials cached locally; no access keys created).
   - GitHub: `gh auth login --web`.
4. Created the repo skeleton (`README.md`, `.gitignore`, `.gitattributes`, `docs/`) and pushed the first commit.

## Concepts
- **Region vs AZ**: a region (`ap-southeast-1`, Singapore) is a geographic area made of several isolated
  Availability Zones (`ap-southeast-1a/b/c`). Some resources are regional (VPC, S3 bucket, RDS subnet group),
  some are zonal (subnet, EC2 instance, EBS volume) — this matters a lot in Phase 4.
- **Short-lived vs long-lived credentials**: `aws login` / IAM Identity Center / OIDC hand out temporary
  credentials that expire. Static access keys (`AKIA...`) never expire unless rotated, so they are the #1 cause of
  cloud account leaks. We avoid them everywhere — locally and in CI.
- **Why `.gitattributes` with LF**: scripts like `user_data` and shell scripts run on Linux; CRLF line endings from
  Windows break them (`/bin/bash^M: bad interpreter`).
- **Why ignore `*.tfstate` and `*.tfvars`**: state files contain resource attributes in plain text (sometimes
  passwords); tfvars often hold account-specific values. State goes to an S3 backend from Phase 1.

## Useful commands
```bash
aws sts get-caller-identity          # "whoami" for AWS
aws configure list                   # where credentials/region come from
gh auth status
terraform -version
```

## Interview Q&A
- **Q: How do you give a CI pipeline access to AWS securely?**
  A: Use OIDC federation — the CI provider issues a signed JWT, AWS IAM trusts that issuer and lets a specific
  repo/branch assume a role with `AssumeRoleWithWebIdentity`. No static keys stored as secrets; credentials last
  about an hour. (Implemented in Phase 1.)
- **Q: What would you check first if `terraform plan` says "no valid credential sources found"?**
  A: `aws sts get-caller-identity`, then `AWS_PROFILE` / `AWS_REGION` env vars, expired session, and the provider
  block's `profile`/`region`.
