#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy the persistent Managed Disk that holds the vLLM model weights.

.DESCRIPTION
  Creates, idempotently via Azure CLI:
  
    * Standalone Managed Disk `diskmodels001` in the workload resource group.

  The disk is populated with the model after initial virtual machine creation.

  The disk can be detached from the virtual and retained when recreating the virtual machine.

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
   ./c-workload/03-Deploy-LlmDataDisk.ps1
#>
[CmdletBinding()]
param (
    ## Purpose prefix.
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Workload prefix (matches `a-infrastructure/02-Initialize-WorkloadRg.ps1`).
    [string]$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## The Azure region where the resource is deployed.
    [string]$Region = $ENV:DEPLOY_REGION ?? 'australiaeast',
    ## Instance number uniquifier.
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001',
    ## Disk size in GiB. 8 GiB is enough for one AWQ-INT4 7B model with headroom.
    [int]$SizeGiB = [int]($ENV:DEPLOY_LLM_DISK_GIB ?? 8),
    ## Managed disk SKU.
    [ValidateSet('Standard_LRS','StandardSSD_LRS','Premium_LRS')]
    [string]$Sku = $ENV:DEPLOY_LLM_DISK_SKU ?? 'StandardSSD_LRS'
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$Region = $ENV:DEPLOY_REGION ?? 'australiaeast'
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
$SizeGiB = 8
$Sku = 'StandardSSD_LRS'
#>

$ErrorActionPreference = 'Stop'

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying LLM/vLLM model data disk for '$Environment' in subscription '$SubscriptionId'"

$rgName   = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$rg       = az group show --name $rgName 2>$null | ConvertFrom-Json
if (-not $rg) {
    throw "Workload resource group '$rgName' not found."
}

$appName = "models"
$diskName = "disk$appName$Instance".ToLowerInvariant()
Write-Verbose "Disk name : $diskName"
Write-Verbose "Size      : ${SizeGiB} GiB"
Write-Verbose "SKU       : $Sku"

# CAF tags. Only applied on initial create — see header.
$TagDictionary = [ordered]@{
    WorkloadName       = 'llm'
    ApplicationName    = 'llm-vllm'
    DataClassification = 'Non-business'
    Criticality        = 'Low'
    BusinessUnit       = 'IT'
    Env                = $Environment
}
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

$existing = az disk show --name $diskName --resource-group $rgName 2>$null | ConvertFrom-Json
if ($existing) {
    Write-Verbose "Managed disk '$diskName' already present (size=$($existing.diskSizeGb) GiB, sku=$($existing.sku.name), state=$($existing.diskState)); skipping. No resize, no SKU change, no tag rewrite."
    Write-Verbose "Deploy LLM/vLLM model data disk complete (no-op)."
    return
}

Write-Verbose "Creating managed disk '$diskName' (${SizeGiB} GiB, $Sku, empty)"
az disk create `
    --name $diskName `
    --resource-group $rgName `
    --location $rg.location `
    --size-gb $SizeGiB `
    --sku $Sku `
    --tags $tags `
    --output none
if ($LASTEXITCODE -ne 0) { throw "az disk create '$diskName' failed." }

Write-Verbose "Deploy LLM/vLLM model data disk complete."
