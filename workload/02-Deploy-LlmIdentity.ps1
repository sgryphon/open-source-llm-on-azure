#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy the user-assigned managed identity (UAMI) for the LLM/vLLM VM.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * User-assigned managed identity `id-vllm-dev-001`

.NOTES
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
   ./c-workload/02-Deploy-LlmIdentity.ps1
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

$appName   = 'vllm'
$vmName    = "vm$appName$Instance".ToLowerInvariant()

# Workload RG hosts the UAMI; shared core RG hosts the Key Vault.
$workloadRgName = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$coreRgName     = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$identityName = "id-$vmName-$Environment".ToLowerInvariant()
$kvName         = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()

$workloadRg = az group show --name $workloadRgName 2>$null | ConvertFrom-Json
if (-not $workloadRg) {
    throw "Workload resource group '$workloadRgName' not found."
}
$kv = az keyvault show --name $kvName --resource-group $coreRgName 2>$null | ConvertFrom-Json
if (-not $kv) {
    throw "Shared Key Vault '$kvName' not found in '$coreRgName'."
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

Write-Verbose "Deploy LLM/vLLM managed identity '$identityName' complete."
