<#
.SYNOPSIS
  Create (or rotate) the GitHub Actions CI access key and store it as GitHub Environment secrets.

.DESCRIPTION
  - Creates a new access key for the CI IAM user.
  - Hands the key straight to `gh secret set` — the secret is never printed or written to disk.
  - Deletes every OTHER key of the user (IAM allows max 2 keys, so rotation = create new, delete old).
  - Ensures the GitHub Environment exists and sets non-secret variables (region, state bucket).

  Run it from the repo root after `aws login` and `gh auth login`:
    powershell -ExecutionPolicy Bypass -File .\scripts\rotate-ci-key.ps1
#>
[CmdletBinding()]
param(
  [string]$UserName    = 'aws-workshop-github-ci',
  [string]$Repo        = 'peeraphatphuthong/AWS_Workshop',
  [string]$Environment = 'aws-sandbox',
  [string]$Region      = 'ap-southeast-2',
  [string]$StateBucket = 'aws-workshop-tfstate-525091405764-ap-southeast-2'
)

$ErrorActionPreference = 'Stop'

# Pick up tools installed after this shell started (winget updates PATH only for new sessions).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

function Assert-LastExit([string]$What) {
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

Write-Host "==> Ensuring GitHub environment '$Environment' exists in $Repo"
gh api --method PUT "repos/$Repo/environments/$Environment" --silent
Assert-LastExit 'Create GitHub environment'

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
  Write-Host "==> Storing key as environment secrets (values are not displayed)"
  # --body (not a stdin pipe): Windows PowerShell appends a newline when piping to native exes,
  # which would corrupt the secret.
  gh secret set AWS_ACCESS_KEY_ID     --repo $Repo --env $Environment --body $key.AccessKeyId
  Assert-LastExit 'Set AWS_ACCESS_KEY_ID'
  gh secret set AWS_SECRET_ACCESS_KEY --repo $Repo --env $Environment --body $key.SecretAccessKey
  Assert-LastExit 'Set AWS_SECRET_ACCESS_KEY'
}
catch {
  Write-Warning "Storing secrets failed; deleting the new key so nothing dangling is left."
  aws iam delete-access-key --user-name $UserName --access-key-id $key.AccessKeyId
  throw
}
finally {
  $key = $null; $keyJson = $null
}

Write-Host "==> Setting environment variables"
gh variable set AWS_REGION      --repo $Repo --env $Environment --body $Region
gh variable set TF_STATE_BUCKET --repo $Repo --env $Environment --body $StateBucket

foreach ($old in $oldKeys) {
  Write-Host "==> Deleting old key $old"
  aws iam delete-access-key --user-name $UserName --access-key-id $old
  Assert-LastExit "Delete key $old"
}

Write-Host "Done. Active keys for ${UserName}:"
aws iam list-access-keys --user-name $UserName --query 'AccessKeyMetadata[].{Id:AccessKeyId,Status:Status,Created:CreateDate}' --output table
