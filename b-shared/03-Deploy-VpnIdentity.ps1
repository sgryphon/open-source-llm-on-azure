#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy user-assigned managed identity (UAMI) for the strongSwan VPN VM.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * User-assigned managed identity `id-<Purpose>-strongswan-<Environment>-<Instance>`
      in the shared core resource group.
    * An access-policy entry on the shared Key Vault granting the identity
      `get, list` on secrets (matches what `Key Vault Secrets User` grants
      in RBAC mode).

  The identity is consumed by the strongSwan VM deployment script, which
  binds it to the VM via `az vm create --assign-identity <resource-id>`.
  Keeping the identity lifecycle independent of the VM lifecycle means
  permissions can be (re-)asserted before the VM exists, eliminating any
  cloud-init race against permission propagation and allowing VM rebuilds
  without touching Key Vault permissions.

.NOTES
  PREREQUISITES
  * The Key Vault deployment script in this folder must have run for the
    same parameter set; this script writes an access-policy entry to that
    vault.

  KEY VAULT MODE
  The shared Key Vault is provisioned in access-policy mode (not RBAC mode)
  because the PoC/demo runs under Contributor, which lacks
  `Microsoft.Authorization/roleAssignments/write`. Granting via
  `az keyvault set-policy` is a management-plane write on the vault that
  Contributor has; this keeps the deployment self-sufficient.

  Running these scripts requires the following to be installed:
  * PowerShell, https://github.com/PowerShell/PowerShell
  * Azure CLI, https://docs.microsoft.com/en-us/cli/azure/

  You also need to connect to Azure (log in), and set the desired subscription context.

  Follow standard naming conventions from Azure Cloud Adoption Framework,
  with an additional organisation or subscription identifier (after app name) in global names
  to make them unique.
  https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming

  Follow standard tagging conventions from Azure Cloud Adoption Framework.
  https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging

.EXAMPLE

   az login
   az account set --subscription <subscription id>
   $VerbosePreference = 'Continue'
   ./03-Deploy-VpnIdentity.ps1
#>
[CmdletBinding()]
param (
    ## Purpose prefix (matches the Key Vault deployment script).
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## Identifier for the organisation (or subscription) to make global names unique.
    [string]$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
    ## Instance number uniquifier (matches the Key Vault deployment script).
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))"
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
#>

$ErrorActionPreference = 'Stop'

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying VPN managed identity for '$Purpose' '$Environment' in subscription '$SubscriptionId'"

# Following standard naming conventions from Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming

$rgName       = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$identityName = "id-$Purpose-strongswan-$Environment-$Instance".ToLowerInvariant()
$kvName       = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()

# Resolve RG (must already exist) to get location for the identity resource.
$rg = az group show --name $rgName 2>$null | ConvertFrom-Json
if (-not $rg) { throw "Resource group '$rgName' not found. Run the infrastructure initialization scripts first." }

# Confirm the shared Key Vault exists; we grant access to it.
$kv = az keyvault show --name $kvName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $kv) { throw "Key Vault '$kvName' not found. Run the Key Vault deployment script first." }

# Following standard tagging conventions from Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging

$TagDictionary = [ordered]@{
    DataClassification = 'Non-business'
    Criticality        = 'Low'
    BusinessUnit       = $Purpose
    Env                = $Environment
}

# Convert dictionary to tags format used by Azure CLI create command
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

# ---------------------------------------------------------------------------
# 1. Managed identity (idempotent).
# ---------------------------------------------------------------------------

Write-Verbose "Ensuring user-assigned managed identity '$identityName' in '$rgName'"
$existingIdentity = az identity show --name $identityName --resource-group $rgName 2>$null | ConvertFrom-Json
if ($existingIdentity) {
    Write-Verbose "Managed identity '$identityName' already exists; skipping create"
    $identity = $existingIdentity
} else {
    Write-Verbose "Creating managed identity '$identityName'"
    $identity = az identity create `
        --name $identityName `
        --resource-group $rgName `
        --location $rg.location `
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
# Permissions match what `Key Vault Secrets User` would grant in RBAC mode:
# `get` is required by `az keyvault secret download` in cloud-init; `list`
# is useful for diagnostics. `set-policy` replaces the permissions for the
# named object id on every run, so it is idempotent.

Write-Verbose "Granting 'get, list' secret permissions on '$kvName' to identity '$identityName' ($principalId)"
az keyvault set-policy `
    --name $kvName `
    --resource-group $rgName `
    --object-id $principalId `
    --secret-permissions get list `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az keyvault set-policy failed for identity '$identityName' on '$kvName'" }

Write-Verbose "Deploy VPN managed identity '$identityName' complete"
