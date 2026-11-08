#!/usr/bin/env bash
# FinOps audit: find resources that cost money but do nothing ("orphans") and settings that leak cost.
# Read-only (works with the ReadOnlyAccess plan user). Prints Markdown; in GitHub Actions it is also
# appended to the job summary.
#
#   ./scripts/finops-audit.sh                 # report only (exit 0)
#   STRICT=1 ./scripts/finops-audit.sh        # exit 1 if anything was found (for CI gates)
#
# Needs: aws CLI v2 and GNU date (Linux / Git Bash). No jq: JMESPath (--query) + awk only.
set -euo pipefail

REGION="${AWS_REGION:-ap-southeast-2}"
SNAPSHOT_MAX_AGE_DAYS="${SNAPSHOT_MAX_AGE_DAYS:-30}"
export AWS_PAGER="" AWS_DEFAULT_REGION="$REGION"
TAB=$'\t'

findings=0
out=""
say() { out+="$*"$'\n'; }

# table <tsv rows>: render TSV lines as Markdown table rows
table() {
  local line
  while IFS= read -r line; do
    # `if`, not `[ ] && say`: a false test as the last command makes the function fail under set -e
    if [ -n "$line" ]; then say "| ${line//$TAB/ | } |"; fi
  done <<< "$1"
}

# section <title> <tsv rows> <tab-separated header> <cost hint>  -> counted as findings
section() {
  local title="$1" rows="$2" header="$3" hint="$4" count cols
  if [ -z "$rows" ]; then
    say "### ✅ $title"
    say ""
    return
  fi
  count=$(printf '%s\n' "$rows" | grep -c .)
  findings=$((findings + count))
  cols=$(printf '%s' "$header" | awk -F'\t' '{ for (i = 1; i <= NF; i++) printf "---|" }')
  say "### ⚠️ $title ($count)"
  say "_${hint}_"
  say ""
  say "| ${header//$TAB/ | } |"
  say "|$cols"
  table "$rows"
  say ""
}

count_lines() { printf '%s' "$1" | grep -c . || true; }

cutoff=$(date -u -d "-${SNAPSHOT_MAX_AGE_DAYS} days" +%Y-%m-%dT%H:%M:%S)

say "## FinOps audit — $REGION — $(date -u +%Y-%m-%dT%H:%MZ)"
say ""

# 1. EBS volumes not attached to anything (still billed per GB-month).
rows=$(aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,VolumeType,CreateTime,(Tags[?Key==`Name`].Value)[0]]' --output text)
section "Unattached EBS volumes" "$rows" "Volume${TAB}GiB${TAB}Type${TAB}Created${TAB}Name" \
  'gp3 is about $0.096/GiB-month in Sydney. Snapshot it if unsure, then delete.'

# 2. Elastic IPs not associated (public IPv4 is billed whether used or not).
rows=$(aws ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId,(Tags[?Key==`Name`].Value)[0]]' --output text)
section "Unassociated Elastic IPs" "$rows" "IP${TAB}Allocation${TAB}Name" \
  'Public IPv4 costs $0.005/hour (about $3.6/month) each. Release them.'

# 3. Every public IPv4 in use (also billed while attached).
rows=$(aws ec2 describe-network-interfaces \
  --query 'NetworkInterfaces[?Association.PublicIp!=null].[Association.PublicIp,NetworkInterfaceId,InterfaceType]' --output text)
say "### ℹ️ Public IPv4 addresses in use: $(count_lines "$rows")"
say '_About $3.6/month each. Expected: 1 (the web EIP)._'
say ""

# 4. Stopped instances: compute is free, but their EBS volumes and EIPs are not.
rows=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=stopped \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,(Tags[?Key==`Name`].Value)[0]]' --output text)
say "### ℹ️ Stopped EC2 instances: $(count_lines "$rows")"
say "_Normal at night (office-hours schedule). Their volumes and EIPs keep billing._"
say ""

# 5. Old EBS snapshots we own.
rows=$(aws ec2 describe-snapshots --owner-ids self \
  --query "Snapshots[?StartTime<'${cutoff}'].[SnapshotId,VolumeSize,StartTime,Description]" --output text)
section "EBS snapshots older than ${SNAPSHOT_MAX_AGE_DAYS} days" "$rows" "Snapshot${TAB}GiB${TAB}Created${TAB}Description" \
  'About $0.055/GiB-month. Keep only what a retention policy needs (AWS Backup / DLM).'

# 6. Manual RDS snapshots survive the DB instance and are never cleaned up automatically.
rows=$(aws rds describe-db-snapshots --snapshot-type manual \
  --query 'DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage,SnapshotCreateTime,DBInstanceIdentifier]' --output text)
section "Manual RDS snapshots" "$rows" "Snapshot${TAB}GiB${TAB}Created${TAB}From instance" \
  "Billed as backup storage. Delete if not needed."

# 7. RDS instances and their status (a stopped DB starts again by itself after 7 days).
rows=$(aws rds describe-db-instances \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus,MultiAZ,AllocatedStorage]' --output text)
say "### ℹ️ RDS instances"
say ""
say "| Instance | Class | Status | Multi-AZ | GiB |"
say "|---|---|---|---|---|"
table "$rows"
say ""

# 8. Log groups with "Never expire" retention: log storage grows forever.
rows=$(aws logs describe-log-groups \
  --query 'logGroups[?retentionInDays==null].[logGroupName,storedBytes]' --output text)
section "Log groups without retention" "$rows" "Log group${TAB}Stored bytes" \
  'Storage is about $0.03/GB-month forever. Set retention_in_days in Terraform.'

# 9. Burstable (T) instances in "unlimited" CPU credit mode (surplus credits are billed).
ids=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=running,stopped \
  --query 'Reservations[].Instances[?starts_with(InstanceType,`t`)].InstanceId' --output text)
rows=""
if [ -n "$ids" ]; then
  # shellcheck disable=SC2086 # word splitting is intended: one argument per instance ID
  rows=$(aws ec2 describe-instance-credit-specifications --instance-ids $ids \
    --query 'InstanceCreditSpecifications[?CpuCredits==`unlimited`].[InstanceId,CpuCredits]' --output text)
fi
section "Burstable instances in unlimited credit mode" "$rows" "Instance${TAB}Mode" \
  'Sustained high CPU is billed at $0.05/vCPU-hour extra. Prefer standard unless you need bursts.'

# 10. ECR images without tags (should be expired by a lifecycle policy).
rows=""
for repo in $(aws ecr describe-repositories --query 'repositories[].repositoryName' --output text); do
  n=$(aws ecr list-images --repository-name "$repo" --filter tagStatus=UNTAGGED --query 'length(imageIds)' --output text)
  if [ "$n" != "0" ]; then rows+="${repo}${TAB}${n}"$'\n'; fi
done
rows="${rows%$'\n'}"
section "ECR repositories with untagged images" "$rows" "Repository${TAB}Untagged images" \
  'About $0.10/GB-month. Add or verify an ECR lifecycle policy.'

# 11. Month-to-date cost by service (Cost Explorer API calls cost $0.01 each).
start=$(date -u +%Y-%m-01)
end=$(date -u -d tomorrow +%Y-%m-%d)
if [ "$start" = "$(date -u +%Y-%m-%d)" ]; then start=$(date -u -d yesterday +%Y-%m-%d); fi
if ce=$(aws ce get-cost-and-usage --time-period "Start=$start,End=$end" --granularity MONTHLY       --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE       --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' --output text 2>/dev/null); then
  say "### 💰 Month-to-date cost ($start to today)"
  say ""
  say "| Service | USD |"
  say "|---|---|"
  rows=$(printf '%s\n' "$ce" | awk -F'\t' 'NF == 2 && $2 >= 0.01 { printf "%s\t%.2f\n", $1, $2 }' | sort -t "$TAB" -k2 -rn)
  table "$rows"
  total=$(printf '%s\n' "$ce" | awk -F'\t' 'NF == 2 { t += $2 } END { printf "%.2f", t }')
  say "| **Total** | **$total** |"
  say ""
  say "_Credits or sandbox discounts can make this 0. Data lags up to 24h._"
else
  say "### 💰 Month-to-date cost: not available (missing ce:GetCostAndUsage permission?)"
fi
say ""
say "**Findings: $findings**"

printf '%s' "$out"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s' "$out" >> "$GITHUB_STEP_SUMMARY"; fi

if [ "${STRICT:-0}" = "1" ] && [ "$findings" -gt 0 ]; then exit 1; fi
