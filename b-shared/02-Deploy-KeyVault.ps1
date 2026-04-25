#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy Azure Key Vault into core shared resource group.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * Key Vault `log-llm-shared-dev-001`

.NOTES
  This creates Azure Monitor in the shared core resource group.

  Running these scripts requires the following to be installed:
  * PowerShell, https://github.com/PowerShell/PowerShell
  * Azure CLI, https://docs.microsoft.com/en-us/cli/azure/

  You also need to connect to Azure (log in), and set the desired subscription context.

  Follow standard naming conventions from Azure Cloud Adoption Framework, 
  with an additional organisation or subscription identifier (after app name) in global names 
  to make them unique.
  https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming

  Follow standard tagging conventions from  Azure Cloud Adoption Framework.
  https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging

.EXAMPLE

   az login
   az account set --subscription <subscription id>
   $VerbosePreference = 'Continue'
   ./02-Deploy-KeyVault.ps1
#>
[CmdletBinding()]
param (
    ## Purpose prefix
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## Identifier for the organisation (or subscription) to make global names unique.
    [string]$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
    ## Instance number uniquifier
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))"
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
#>

$ErrorActionPreference="Stop"

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying shared Azure Monitor in subscription '$SubscriptionId'"

# Following standard naming conventions from Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming
# With an additional organisation or subscription identifier (after app name) in global names to make them unique 

$rgName = "rg-$Purpose-core-$Instance".ToLowerInvariant()

$kvName = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()

# Following standard tagging conventions from  Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging

$TagDictionary = [ordered]@{
    DataClassification = 'Non-business'
    Criticality        = 'Low'
    BusinessUnit       = $Purpose
    Env                = $Environment
}

# Convert dictionary to tags format used by Azure CLI create command
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

# Copy location details from the RG
$rg = az group show --name $rgName | ConvertFrom-Json

# Create

Write-Verbose "Creating key vault $kvName"

$existingVault = az keyvault show --name $kvName --resource-group $rgName 2>$null
if ($LASTEXITCODE -eq 0 -and $existingVault) {
    Write-Verbose "Key vault $kvName already exists; skipping create"
} else {
    # PoC/demo convenience: use access-policy mode (not RBAC mode), so that
    # Contributor on the RG is sufficient to self-grant data-plane permissions.
    # For production, flip to RBAC mode and assign 'Key Vault Secrets Officer'
    # etc. via a deployment principal that has UAA pre-provisioned.

    az keyvault create `
      --resource-group $rgName `
      -l $rg.location `
      --name $kvName `
      --enable-rbac-authorization false `
      --tags $tags
    if ($LASTEXITCODE -ne 0) { throw "az keyvault create failed for '$kvName'" }
}

$signedInUserObjectId = az ad signed-in-user show --query id --output tsv
if ($LASTEXITCODE -ne 0 -or -not $signedInUserObjectId) {
    throw "Unable to resolve signed-in user object id via 'az ad signed-in-user show'"
}
Write-Verbose "Granting signed-in user $signedInUserObjectId broad data-plane permissions on $kvName"

$secretPerms = @('get','list','set','delete','recover','backup','restore','purge')
$certPerms   = @('get','list','create','import','delete','update','managecontacts',
                 'getissuers','listissuers','setissuers','deleteissuers','manageissuers',
                 'recover','backup','restore','purge')
$keyPerms    = @('get','list','create','import','delete','update','recover','backup','restore','purge',
                 'encrypt','decrypt','sign','verify','wrapKey','unwrapKey')

az keyvault set-policy `
    --name $kvName `
    --resource-group $rgName `
    --object-id $signedInUserObjectId `
    --secret-permissions @secretPerms `
    --certificate-permissions @certPerms `
    --key-permissions @keyPerms | Out-Null
if ($LASTEXITCODE -ne 0) { throw "az keyvault set-policy failed for '$kvName'" }

Write-Verbose "Deploy Key Vault $kvName complete"
