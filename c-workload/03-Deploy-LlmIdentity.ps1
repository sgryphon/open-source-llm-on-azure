#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy the user-assigned managed identity (UAMI) for the LLM/vLLM VM.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * User-assigned managed identity `id-llm-vllm-<Environment>-<Instance>`
      in the workload resource group.
    * An access-policy entry on the shared Key Vault granting the identity
      `get, list` on **secrets** (matches what `Key Vault Secrets User`
      grants in RBAC mode).

  Pre-creating the UAMI (rather than relying on a system-assigned identity
  that only materialises after `az vm create` returns) eliminates any
  cloud-init race against permission propagation and lets the VM be
  rebuilt without touching Key Vault permissions.

.NOTES
  PERMISSIONS BOUNDARY
  This script ONLY grants `get, list` on secrets via Key Vault access
  policy. It does NOT call `az role assignment create` for any RBAC role
  (no Storage Blob Data Reader, no Storage Blob Data Contributor, no
  Reader, no Contributor). It does NOT grant access to keys or
  certificates inside Key Vault.

  KEY VAULT MODE
  The shared Key Vault is in access-policy mode (per
  `b-shared/02-Deploy-KeyVault.ps1`). This script does NOT switch the
  vault to RBAC mode.

.EXAMPLE

   az login
   az account set --subscription <subscription id>
   $VerbosePreference = 'Continue'
   ./c-workload/03-Deploy-LlmIdentity.ps1
#>
[CmdletBinding()]
param (
    ## Purpose prefix.
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Workload prefix (matches `a-infrastructure/02-Initialize-WorkloadRg.ps1`).
    [string]$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## Identifier for the organisation (or subscription) to make global names unique.
    [string]$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
    ## Instance number uniquifier.
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))"
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
#>

$ErrorActionPreference = 'Stop'

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying LLM/vLLM managed identity for '$Environment' in subscription '$SubscriptionId'"

# Workload RG hosts the UAMI; shared core RG hosts the Key Vault.
$workloadRgName = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$coreRgName     = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$identityName   = "id-$Purpose-vllm-$Environment-$Instance".ToLowerInvariant()
$kvName         = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()

$workloadRg = az group show --name $workloadRgName 2>$null | ConvertFrom-Json
if (-not $workloadRg) {
    throw "Workload resource group '$workloadRgName' not found. Run a-infrastructure/02-Initialize-WorkloadRg.ps1 first."
}
$kv = az keyvault show --name $kvName --resource-group $coreRgName 2>$null | ConvertFrom-Json
if (-not $kv) {
    throw "Shared Key Vault '$kvName' not found in '$coreRgName'. Run b-shared/02-Deploy-KeyVault.ps1 first."
}

# CAF tags (matches the design's tag table for this workload).
$TagDictionary = [ordered]@{
    WorkloadName       = 'llm'
    ApplicationName    = 'llm-vllm'
    DataClassification = 'Non-business'
    Criticality        = 'Low'
    BusinessUnit       = 'IT'
    Env                = $Environment
}
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

# ---------------------------------------------------------------------------
# 1. UAMI (idempotent).
# ---------------------------------------------------------------------------

Write-Verbose "Ensuring user-assigned managed identity '$identityName' in '$workloadRgName'"
$existingIdentity = az identity show --name $identityName --resource-group $workloadRgName 2>$null | ConvertFrom-Json
if ($existingIdentity) {
    Write-Verbose "Managed identity '$identityName' already exists; skipping create"
    $identity = $existingIdentity
} else {
    Write-Verbose "Creating managed identity '$identityName'"
    $identity = az identity create `
        --name $identityName `
        --resource-group $workloadRgName `
        --location $workloadRg.location `
        --tags $tags | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $identity) {
        throw "az identity create failed for '$identityName'"
    }
}

$principalId = $identity.principalId
$clientId    = $identity.clientId
$identityId  = $identity.id
if (-not $principalId) { throw "Managed identity '$identityName' has no principalId." }
Write-Verbose "Identity principalId: $principalId"
Write-Verbose "Identity clientId:    $clientId"
Write-Verbose "Identity resourceId:  $identityId"

# ---------------------------------------------------------------------------
# 2. Key Vault access-policy entry (idempotent).
# ---------------------------------------------------------------------------
# `set-policy` replaces the permissions for the named object id on every
# run, so it is idempotent. Permissions match what `Key Vault Secrets User`
# would grant in RBAC mode: `get` (required by cloud-init) + `list`
# (useful for diagnostics).

Write-Verbose "Granting 'get, list' secret permissions on '$kvName' to identity '$identityName' ($principalId)"
az keyvault set-policy `
    --name $kvName `
    --resource-group $coreRgName `
    --object-id $principalId `
    --secret-permissions get list `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az keyvault set-policy failed for identity '$identityName' on '$kvName'" }

# ---------------------------------------------------------------------------
# 3. (Negative invariant) Assert no Azure RBAC role assignments exist for
#    this UAMI. The script never creates one; this check guards against a
#    future edit that might.
# ---------------------------------------------------------------------------

$roleAssignmentsJson = az role assignment list --assignee $principalId --all --output json 2>$null
$roleAssignments = $roleAssignmentsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($roleAssignments -and $roleAssignments.Count -gt 0) {
    Write-Warning "Identity '$identityName' has $($roleAssignments.Count) RBAC role assignment(s); this script does not create them. Operator may have granted them externally:"
    foreach ($ra in $roleAssignments) {
        Write-Warning "  - $($ra.roleDefinitionName) on $($ra.scope)"
    }
}

Write-Verbose "Deploy LLM/vLLM managed identity '$identityName' complete."
