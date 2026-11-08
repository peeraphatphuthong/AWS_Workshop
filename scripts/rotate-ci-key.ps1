<#
.SYNOPSIS
  Create (or rotate) the GitHub Actions CI access key and store it as GitHub Environment secrets.

.DESCRIPTION
  - Creates a new access key for the CI IAM user.
  - Hands the key straight to `gh secret set` - the secret is never printed or written to disk.
  - Deletes every OTHER key of the user (IAM allows max 2 keys, so rotation = create new, delete old).
  - Ensures the GitHub Environment exists and sets non-secret variables (region, state bucket).

  Run it from the repo root after `aws login` and `gh auth login`:
    # read-only user for pull-request plan jobs
    powershell -ExecutionPolicy Bypass -File .\scripts\rotate-ci-key.ps1 -UserName aws-workshop-github-plan -Environments aws-plan
    # deploy user for jobs on main (same key stored in both environments)
    powershell -ExecutionPolicy Bypass -File .\scripts\rotate-ci-key.ps1 -UserName aws-workshop-github-ci -Environments aws-dev,aws-dev-infra
#>
[CmdletBinding()]
param(
  [string]$UserName     = 'aws-workshop-github-ci',
  [string]$Repo         = 'peeraphatphuthong/AWS_Workshop',
  # Comma-separated when called with -File (e.g. "aws-dev,aws-dev-infra").
  [string[]]$Environments = @('aws-dev', 'aws-dev-infra'),
  [string]$Region       = 'ap-southeast-2',
  [string]$StateBucket  = 'aws-workshop-tfstate-525091405764-ap-southeast-2'
)
$Environments = @($Environments | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$ErrorActionPreference = 'Stop'

# Pick up tools installed after this shell started (winget updates PATH only for new sessions).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

function Assert-LastExit([string]$What) {
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

foreach ($envName in $Environments) {
  gh api "repos/$Repo/environments/$envName" --silent
  if ($LASTEXITCODE -ne 0) { throw "GitHub environment '$envName' not found - run scripts/setup-github-environments.ps1 first" }
}

$oldKeys = @(aws iam list-access-keys --user-name $UserName --query 'AccessKeyMetadata[].AccessKeyId' --output text)
Assert-LastExit 'List access keys'
$oldKeys = @($oldKeys -split '\s+' | Where-Object { $_ })

if ($oldKeys.Count -ge 2) {
  throw "User already has 2 keys ($($oldKeys -join ', ')). Delete one manually before rotating."
}

Write-Host "==> Creating new access key for $UserName"
$keyJson = aws iam create-access-key --user-name $UserName --output json
Assert-LastExit 'Create access key'
$key = ($keyJson | Out-String | ConvertFrom-Json).AccessKey

try {
  foreach ($envName in $Environments) {
    Write-Host "==> Storing key in environment '$envName' (values are not displayed)"
    # --body (not a stdin pipe): Windows PowerShell appends a newline when piping to native exes,
    # which would corrupt the secret.
    gh secret set AWS_ACCESS_KEY_ID     --repo $Repo --env $envName --body $key.AccessKeyId
    Assert-LastExit "Set AWS_ACCESS_KEY_ID in $envName"
    gh secret set AWS_SECRET_ACCESS_KEY --repo $Repo --env $envName --body $key.SecretAccessKey
    Assert-LastExit "Set AWS_SECRET_ACCESS_KEY in $envName"
  }
}
catch {
  Write-Warning "Storing secrets failed; deleting the new key so nothing dangling is left."
  aws iam delete-access-key --user-name $UserName --access-key-id $key.AccessKeyId
  throw
}
finally {
  $key = $null; $keyJson = $null
}

foreach ($envName in $Environments) {
  Write-Host "==> Setting variables in '$envName'"
  gh variable set AWS_REGION      --repo $Repo --env $envName --body $Region
  gh variable set TF_STATE_BUCKET --repo $Repo --env $envName --body $StateBucket
}

foreach ($old in $oldKeys) {
  Write-Host "==> Deleting old key $old"
  aws iam delete-access-key --user-name $UserName --access-key-id $old
  Assert-LastExit "Delete key $old"
}

Write-Host "Done. Active keys for ${UserName}:"
aws iam list-access-keys --user-name $UserName --query 'AccessKeyMetadata[].{Id:AccessKeyId,Status:Status,Created:CreateDate}' --output table
