#!/usr/bin/env pwsh

<# .SYNOPSIS
  Generate the vLLM bearer-token API key and store it in the shared Key Vault.

.DESCRIPTION
  Creates, idempotently via Azure CLI, in the shared Key Vault produced by
  `b-shared/02-Deploy-KeyVault.ps1`:

    * Secret `vllm-api-key` containing a 256-bit cryptographically random
      value, encoded as URL-safe base64 (no padding).

  Without `-Rotate`, an existing `vllm-api-key` secret is left untouched
  and the script exits 0. With `-Rotate`, a new secret value is set, which
  creates a new Key Vault secret version. Any prior versions remain in
  Key Vault history per the vault's retention policy.

  The Key Vault is consumed in access-policy mode (matching `b-shared`).
  This script does NOT switch the vault to RBAC mode.

.NOTES
  The 256-bit value is generated on the operator's machine via the .NET
  `RandomNumberGenerator` (cryptographic) and never written to disk. It
  flows directly into `az keyvault secret set` via stdin.

  AGENTS.md: secrets are accepted via env var (`DEPLOY_*`), never via a
  file checked into the repo. This script generates rather than accepts.

.EXAMPLE

   az login
   az account set --subscription <subscription id>
   $VerbosePreference = 'Continue'
   ./c-workload/02-Deploy-LlmKeyVaultSecret.ps1

.EXAMPLE

   # Rotate the existing key.
   ./c-workload/02-Deploy-LlmKeyVaultSecret.ps1 -Rotate
#>
[CmdletBinding()]
param (
    ## Purpose prefix (matches `b-shared`).
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## Identifier for the organisation (or subscription) to make global names unique.
    [string]$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
    ## Instance number uniquifier (matches `b-shared`).
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001',
    ## Secret name in the shared Key Vault.
    [string]$SecretName = $ENV:DEPLOY_VLLM_API_KEY_SECRET_NAME ?? 'vllm-api-key',
    ## Set a new secret version even if the secret already exists.
    [switch]$Rotate
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))"
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
$SecretName = 'vllm-api-key'
$Rotate = $false
#>

$ErrorActionPreference = 'Stop'

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying vLLM API key secret for '$Environment' in subscription '$SubscriptionId'"

$rgName = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$kvName = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()

$kv = az keyvault show --name $kvName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $kv) {
    throw "Shared Key Vault '$kvName' not found in '$rgName'. Run b-shared/02-Deploy-KeyVault.ps1 first."
}

# Check existence (existence-only — do NOT fetch the value, we don't need it).
$existing = az keyvault secret show --vault-name $kvName --name $SecretName 2>$null | ConvertFrom-Json
if ($existing -and -not $Rotate) {
    Write-Verbose "Secret '$SecretName' already present in '$kvName'; skipping (re-run with -Rotate to set a new version)."
    return
}

if ($existing -and $Rotate) {
    Write-Verbose "Secret '$SecretName' present in '$kvName'; -Rotate set, will create a new version."
} else {
    Write-Verbose "Secret '$SecretName' not present in '$kvName'; will create."
}

# Generate a 256-bit cryptographically random value and encode as URL-safe
# base64 with no padding (RFC 4648 §5). 32 bytes -> 43-char string.
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$base64 = [Convert]::ToBase64String($bytes)
$urlSafe = $base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')

# Length sanity-check (32 bytes -> ceil(32*8/6) = 43 chars, then with two
# pad '=' stripped => 43). Any deviation indicates encoding logic error.
if ($urlSafe.Length -ne 43) {
    throw "Generated API key has unexpected length $($urlSafe.Length); aborting before write."
}

Write-Verbose "Setting secret '$SecretName' in '$kvName' (256-bit URL-safe base64)"
az keyvault secret set `
    --vault-name $kvName `
    --name $SecretName `
    --value $urlSafe `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set '$SecretName' failed." }

# Don't echo the value. Operators retrieve it on demand from Key Vault.
Write-Verbose "Deploy vLLM API key secret '$SecretName' complete."
