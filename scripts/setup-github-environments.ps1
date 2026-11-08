<#
.SYNOPSIS
  Create/update the GitHub environments used by the pipelines (idempotent). No secrets involved.

  aws-plan       any branch           read-only AWS user  -> PR terraform plan, access check
  aws-dev        main only            deploy AWS user     -> push image to ECR + deploy app (automatic)
  aws-dev-infra  main only + approval deploy AWS user     -> terraform apply (a human approves the plan)
#>
[CmdletBinding()]
param(
  [string]$Repo     = 'peeraphatphuthong/AWS_Workshop',
  [string]$Reviewer = 'peeraphatphuthong'
)
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

$reviewerId = [int](gh api "users/$Reviewer" --jq '.id')

function Set-Environment([string]$Name, [hashtable]$Body) {
  $file = New-TemporaryFile
  try {
    $Body | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding ascii
    gh api --method PUT "repos/$Repo/environments/$Name" --input $file --silent
    if ($LASTEXITCODE -ne 0) { throw "Failed to configure environment $Name" }
    Write-Host "configured environment $Name"
  } finally { Remove-Item $file }
}

function Set-MainOnly([string]$Name) {
  $existing = gh api "repos/$Repo/environments/$Name/deployment-branch-policies" --jq '.branch_policies[].name'
  if ($existing -notcontains 'main') {
    gh api --method POST "repos/$Repo/environments/$Name/deployment-branch-policies" -f name=main -f type=branch --silent
  }
}

$mainOnly = @{ protected_branches = $false; custom_branch_policies = $true }

Set-Environment 'aws-plan' @{ deployment_branch_policy = $null }

Set-Environment 'aws-dev' @{ deployment_branch_policy = $mainOnly }
Set-MainOnly 'aws-dev'

Set-Environment 'aws-dev-infra' @{
  deployment_branch_policy = $mainOnly
  reviewers                = @(@{ type = 'User'; id = $reviewerId })
  prevent_self_review      = $false  # solo project: the author may approve their own apply
}
Set-MainOnly 'aws-dev-infra'

# (no double quotes inside --jq: Windows PowerShell 5.1 strips them when calling native exes)
gh api "repos/$Repo/environments" --jq '.environments[] | {name, rules: [.protection_rules[].type]}'
