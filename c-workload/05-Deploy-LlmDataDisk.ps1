#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy the persistent Managed Disk that holds the vLLM model weights.

.DESCRIPTION
  Creates, idempotently via Azure CLI, a standalone Managed Disk
  `disk-llm-vllm-models-<env>-001` in the workload resource group:

    * SKU: `StandardSSD_LRS` (cheapest tier that survives detach).
    * Size: 8 GiB (Qwen2.5-Coder-7B-Instruct AWQ-INT4 fits in ~5.5 GiB
      on disk; the headroom covers the ext4 filesystem overhead and a
      future second model directory).
    * Created standalone — never as part of `az vm create
      --data-disk-sizes-gb`. The disk's lifecycle is independent of any
      VM, which is the whole point: rebuilding the VM (`util/Detach-
      LlmModelDisk.ps1 -DeleteVm` followed by re-running `06-Deploy-
      LlmVm.ps1`) reattaches the same disk and avoids re-downloading
      ~5.5 GiB from Hugging Face every time.

  On re-run with the disk already present this script exits 0 without
  touching it: no resize, no SKU change, no tag rewrite. Resizing or
  retyping a populated model disk is destructive enough that doing it
  silently as a side-effect of a redeploy would be a footgun; if the
  operator wants either, they remove the disk explicitly first.

.NOTES
  The disk is filesystem-formatted by cloud-init on first VM boot
  (`mkfs.ext4 -L llm-models`), guarded by a `blkid` check so subsequent
  reattaches do not reformat. The model files are written by
  `util/Download-LlmModelToDisk.ps1` after the VM is up.

.EXAMPLE

   az login
   az account set --subscription <subscription id>
   $VerbosePreference = 'Continue'
   ./c-workload/05-Deploy-LlmDataDisk.ps1
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
    throw "Workload resource group '$rgName' not found. Run a-infrastructure/02-Initialize-WorkloadRg.ps1 first."
}

$diskName = "disk-$Purpose-vllm-models-$Environment-$Instance".ToLowerInvariant()
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
