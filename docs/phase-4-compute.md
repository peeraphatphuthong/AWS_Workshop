# Phase 4 — Compute (EC2, Elastic IP, EBS, IAM Instance Profile, SSM) + First Real Deploy

## What was built
| File | Resources |
|---|---|
| `infra/iam_instance.tf` | Role `/aws-workshop/aws-workshop-dev-web` (SSM core + ECR read-only + read `/retail-health/dev/*` params), instance profile |
| `infra/compute.tf` | `aws_instance.web` (t3.micro, `10.20.1.50`, IMDSv2, encrypted gp3 root), `aws_ebs_volume.app_data` (gp3 10 GB, encrypted), `aws_volume_attachment`, `aws_eip.web`, SSM parameter `/retail-health/dev/app/image-tag` |
| `infra/templates/user_data.sh.tftpl` | Bootstrap: Docker + Compose (checksum-verified), find/format/mount EBS by volume ID, write app files, install `/usr/local/bin/deploy-app`, run first deploy |

Result: **http://13.54.239.178** serves the dashboard (EIP may change if the stack is destroyed/recreated —
use `terraform output web_url`).

```
Internet ──► EIP 13.54.239.178 ──► ENI 10.20.1.50 (public-a, ap-southeast-2a)
                                   └─ EC2 t3.micro (AL2023)
                                       ├─ nginx:1.28-alpine  :80 ──► app:3000 (ECR :<sha>)
                                       └─ /mnt/app-data (EBS gp3 10 GB, xfs) ◄── bind mount /data
Instance role ─► SSM (shell, run command) · ECR (pull) · Parameter Store (desired image tag)
```

## Deployment model
```
Parameter Store: /retail-health/dev/app/image-tag = <git sha>     (Terraform creates once, CI owns the value)
        │
deploy-app (on host): read tag → ECR login → write .env (APP_IMAGE) → compose pull → up -d → curl /healthz
```
- Terraform `ignore_changes = [value]` on the parameter → app releases don't need `terraform apply`.
- Phase 6 will make CI: push image → `aws ssm put-parameter` → `aws ssm send-command ... deploy-app`.

## Verification that was run
```powershell
Invoke-RestMethod http://<eip>/api/status          # ec2 ok (AZ 2a, 10.20.1.50, EIP), ebs ok (9.94 GiB), db not_configured
aws ssm describe-instance-information               # PingStatus Online
aws ssm send-command --document-name AWS-RunShellScript ...   # lsblk, fstab, docker compose ps, user-data log
Test-NetConnection <eip> -Port 22                   # False — no SSH exposed
terraform plan -detailed-exitcode                   # 0 — no drift
```
Interactive shell without SSH: install the Session Manager plugin, then `aws ssm start-session --target <instance-id>`.

## Problems hit during this phase (real debugging, good interview stories)

### 1. `-target` exposed a hidden dependency
`terraform plan -target=aws_volume_attachment.app_data` planned the instance **without** the SSM/ECR policy
attachments. The instance only references the *instance profile*, not the policy attachments, so Terraform saw no
dependency. Consequences:
- with `-target`: instance boots with a role that can't pull from ECR → bootstrap fails;
- without `-target`: attachments and instance are created **in parallel** → race condition on first boot.

Fix: `depends_on` listing the policy attachments + a `retry` helper in `deploy-app` for IAM eventual consistency.
Lesson: `-target` only includes the target and what it *references* — great for exposing missing dependencies,
dangerous as a routine workflow.

### 2. SSM reserved parameter names
`AccessDeniedException: No access to reserved parameter name: aws-workshop/dev/app/image-tag`.
Parameter names starting with `aws` or `ssm` (any case) are reserved by AWS. Moved app params to
`/retail-health/dev/...`. The failed apply left some resources created — Terraform state recorded them, so the next
apply simply continued (`4 to add, 1 to change`). Applies are **not transactional**.

### 3. PowerShell splits `-target=a.b`
`terraform plan -target=aws_volume_attachment.app_data` → "Too many command line arguments". PowerShell treats the
`.` as an argument boundary. Quote it: `terraform plan "-target=aws_volume_attachment.app_data"` (also needed for
`-replace=...` and indexed addresses like `'aws_subnet.this["public-a"]'`).

### 4. Template escaping
A comment containing a dollar-brace sequence in `user_data.sh.tftpl` broke `templatefile()`. In templates, bash's
dollar-brace must be written with a doubled dollar sign; plain `$VAR` needs no escaping.

## Concepts
- **EBS is zonal**: the volume's AZ must equal the instance's AZ. Here both derive from the same subnet. Using
  `aws_instance.web.availability_zone` would create a **cycle** (instance user_data needs the volume ID).
- **Finding the right disk on Nitro**: `/dev/sdf` becomes `/dev/nvme1n1`, and the number isn't guaranteed.
  `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol...` is stable. Mount by **UUID** in fstab, with `nofail`.
- **Format only if empty** (`blkid || mkfs`) — re-attaching a volume to a new instance keeps its data.
- **EIP + IGW**: `depends_on = [aws_internet_gateway.main]` — an explicit dependency for a relationship Terraform
  can't see from attribute references.
- **IMDSv2 required + hop limit 2**: blocks SSRF-style credential theft; hop limit 2 lets containers reach IMDS.
- **Instance profile** = container that passes a role to EC2. Credentials rotate automatically; nothing on disk.
- **SSM Session Manager vs SSH**: no port 22, no key pairs, IAM-controlled, every session can be logged.
- **`user_data_replace_on_change`**: user_data only runs on first boot; replacing the instance on change makes
  bootstrap changes actually take effect (immutable infrastructure).
- **`ignore_changes = [ami]`**: a new AL2023 AMI every few weeks would otherwise replace the server on a random plan.
  Patch deliberately with `terraform apply "-replace=aws_instance.web"`.
- **Pinned + verified downloads**: compose plugin `v5.6.1` checked with `sha256sum -c` before running.

## Dependency graph (excerpt of `terraform graph`)
```
aws_volume_attachment.app_data -> aws_instance.web
aws_eip.web                    -> aws_instance.web, aws_internet_gateway.main   (explicit)
aws_instance.web               -> aws_ebs_volume.app_data, aws_iam_instance_profile.web,
                                  aws_iam_role_policy_attachment.web_ssm/web_ecr (explicit), aws_security_group.web,
                                  aws_ssm_parameter.image_tag, aws_ecr_repository.app
aws_ebs_volume.app_data        -> aws_subnet.this
```

## Useful commands
```powershell
terraform plan "-target=aws_volume_attachment.app_data"   # plan a slice of the graph
terraform apply "-replace=aws_instance.web"                # rebuild the host (new AMI / bootstrap test)
terraform state list
terraform state show aws_instance.web
terraform graph | Select-String '->'
aws ec2 get-console-output --instance-id <id> --latest --output text   # see user_data logs without logging in
```

## Interview Q&A
- **Q: You attached an EBS volume with Terraform. What else must happen before the app can use it?**
  A: In the OS: find the device (NVMe by-id), create a filesystem only if none exists, mount it, add an fstab entry by
  UUID with `nofail`, set ownership for the app user. Then bind-mount into the container.
- **Q: `aws_volume_attachment` fails with "volume and instance in different AZs". Fix?**
  A: EBS is zonal. Derive both AZs from the same source (subnet or instance), never hard-code them separately.
  To move data across AZs: snapshot → create volume from snapshot in the target AZ.
- **Q: Implicit vs explicit dependency — give a real example where you needed `depends_on`.**
  A: EIP needs the IGW attached; the instance's first boot needs IAM policy attachments that it doesn't reference.
- **Q: When is `-target` appropriate?**
  A: Break-glass fixes, bootstrapping, or investigating the graph. Not routine — it skips dependencies you didn't
  reference and leaves state partially applied. Follow with a full plan.
- **Q: How do you access a private EC2 instance without SSH?**
  A: SSM Session Manager (agent + `AmazonSSMManagedInstanceCore`, outbound HTTPS to SSM endpoints or VPC endpoints).
- **Q: What does IMDSv2 protect against?**
  A: SSRF: an attacker making the app GET `169.254.169.254/.../iam/security-credentials/` can't do the PUT with a
  custom header needed for the token, and the hop limit stops forwarded requests.
- **Q: A `terraform apply` failed halfway. What now?**
  A: State keeps what was created. Fix the cause, run `plan` again — it shows only the remaining work. Don't delete
  the half-created resources manually (that causes drift).

## Cost & stopping
| Resource | Price (ap-southeast-2) | Per day |
|---|---|---|
| EC2 t3.micro | ~$0.0132/h | ~$0.32 |
| Public IPv4 (EIP) | $0.005/h | $0.12 |
| EBS gp3 10 GB + root 8 GB | $0.096/GB-month | ~$0.06 |

**≈ $0.50/day** while running. Options when pausing:
- `aws ec2 stop-instances --instance-ids <id>` → stops EC2 compute charges; EIP and EBS still charge (~$0.18/day).
- `terraform destroy "-target=aws_eip.web" "-target=aws_instance.web" ...` or full `terraform destroy` in `infra/`
  for $0 (the EBS data is lost unless snapshotted).
