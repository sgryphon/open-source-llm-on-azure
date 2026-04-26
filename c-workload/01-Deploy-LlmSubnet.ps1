#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy the LLM workload subnet and its NSG into the existing workload VNet.

.DESCRIPTION
  Creates, idempotently via Azure CLI, inside the workload resource group
  produced by `a-infrastructure/02-Initialize-WorkloadRg.ps1`:

    * Network security group `nsg-llm-vllm-<env>-001` with three inbound
      allow rules:

        Priority 1000  AllowSshInbound    TCP 22  source *
        Priority 1010  AllowHttpInbound   TCP 80  source *
        Priority 1020  AllowHttpsInbound  TCP 443 source *

      Default deny-inbound from the platform NSG default chain handles
      everything else. No outbound rules are added (Azure's default
      outbound-allow is sufficient for `apt`, `pip`, ACME, NVIDIA, and
      Hugging Face).

    * Subnet `snet-llm-vllm-<env>-<region>-001` inside the existing workload
      VNet `vnet-llm-workload-<env>-<region>-001`, dual-stack with an IPv6
      `/64` and an IPv4 `/27` derived deterministically from `-UlaGlobalId`
      (the same hash used by `a-infrastructure/02`) and the workload-VNet
      ID `02` (matching `DEPLOY_WORKLOAD_VNET_ID` default in
      `a-infrastructure/02`).

      Subnet ID slot `<ss>` is `01` for this subnet; the resulting prefixes
      are `fd<gg>:<gggg>:<gggggg>:0201::/64` (IPv6) and
      `10.<gg>.2.32/27` (IPv4).

    * Subnet-NSG association.

.NOTES
  Idempotency: every `create` is guarded by a `show` pre-check.

  AGENTS.md: dual-stack IPv6 + IPv4, addressing derived deterministically
  from the subscription id, no hardcoded addresses.

.EXAMPLE

   az login
   az account set --subscription <subscription id>
   $VerbosePreference = 'Continue'
   ./c-workload/01-Deploy-LlmSubnet.ps1
#>
[CmdletBinding()]
param (
    ## Purpose prefix (matches `a-infrastructure/`).
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Workload prefix (matches `a-infrastructure/02-Initialize-WorkloadRg.ps1`).
    [string]$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## The Azure region where the resource is deployed.
    [string]$Region = $ENV:DEPLOY_REGION ?? 'australiaeast',
    ## Instance number uniquifier (matches `a-infrastructure/`).
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001',
    ## Ten-character IPv6 ULA Global ID (MUST match the workload-RG/VNet script).
    [string]$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10),
    ## Two-character workload-VNet ID (MUST match the workload-RG/VNet script).
    [string]$WorkloadVnetId = $ENV:DEPLOY_WORKLOAD_VNET_ID ?? '02',
    ## Two-character subnet ID inside the workload VNet (default `01` for the LLM/vLLM subnet).
    [string]$SubnetId = $ENV:DEPLOY_LLM_SUBNET_ID ?? '01'
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$Region = $ENV:DEPLOY_REGION ?? 'australiaeast'
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10)
$WorkloadVnetId = $ENV:DEPLOY_WORKLOAD_VNET_ID ?? '02'
$SubnetId = $ENV:DEPLOY_LLM_SUBNET_ID ?? '01'
#>

$ErrorActionPreference = 'Stop'

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying LLM workload subnet for environment '$Environment' in subscription '$SubscriptionId'"

# Resolve the workload RG + VNet (must already exist).
$rgName       = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$vnetName     = "vnet-$Purpose-$Workload-$Environment-$Region-$Instance".ToLowerInvariant()
$nsgName      = "nsg-$Purpose-vllm-$Environment-$Instance".ToLowerInvariant()
$subnetName   = "snet-$Purpose-vllm-$Environment-$Region-$Instance".ToLowerInvariant()

$rg = az group show --name $rgName 2>$null | ConvertFrom-Json
if (-not $rg) {
    throw "Resource group '$rgName' not found. Run a-infrastructure/02-Initialize-WorkloadRg.ps1 first."
}
$vnet = az network vnet show --name $vnetName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $vnet) {
    throw "Workload VNet '$vnetName' not found in '$rgName'. Run a-infrastructure/02-Initialize-WorkloadRg.ps1 first."
}

# Derive subnet prefixes deterministically from UlaGlobalId, WorkloadVnetId, SubnetId.
# UlaGlobalId = gg gggg gggggg (10 hex chars: 2 + 4 + 4)
# Note: the project's per-subnet pattern uses the second-half group as
# `:<vv><ss>::/64`, so we concatenate WorkloadVnetId and SubnetId in that
# slot. With the default workload VNet ID '02' and subnet ID '01' the
# group becomes '0201'.
$prefix          = "fd$($UlaGlobalId.Substring(0, 2)):$($UlaGlobalId.Substring(2, 4)):$($UlaGlobalId.Substring(6))"
$subnetIPv6Addr  = [IPAddress]"$($prefix):$($WorkloadVnetId)$($SubnetId)::"
$subnetIPv6      = "$subnetIPv6Addr/64"

# IPv4: 10.<gg-dec>.<vv-dec>.<ss*32>/27 — same shape as gateway-subnet.
$prefixByte      = [int]"0x$($UlaGlobalId.Substring(0, 2))"
$prefixLength    = 27
$subnetBits      = 32 - $prefixLength
$subnetIdMask    = [Math]::Pow(2, 8 - $subnetBits) - 1
$subnetIPv4      = "10.$prefixByte.$("0x" + $WorkloadVnetId -bAnd 0xFF).$(("0x" + $SubnetId -bAnd $subnetIdMask) -shl $subnetBits)/$prefixLength"

Write-Verbose "Subnet prefixes: IPv6=$subnetIPv6, IPv4=$subnetIPv4"

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
# 1. NSG (idempotent).
# ---------------------------------------------------------------------------

$existingNsg = az network nsg show --name $nsgName --resource-group $rgName 2>$null | ConvertFrom-Json
if ($existingNsg) {
    Write-Verbose "NSG '$nsgName' already present, skipping create."
} else {
    Write-Verbose "Creating NSG '$nsgName'"
    az network nsg create `
        --name $nsgName `
        --resource-group $rgName `
        --location $rg.location `
        --tags $tags `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az network nsg create '$nsgName' failed." }
}

# ---------------------------------------------------------------------------
# 2. NSG inbound rules (idempotent via per-rule show pre-check).
# ---------------------------------------------------------------------------

function Add-NsgRuleIfAbsent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Priority,
        [Parameter(Mandatory)][string]$DestPort
    )
    $existing = az network nsg rule show --nsg-name $nsgName -g $rgName -n $Name 2>$null | ConvertFrom-Json
    if ($existing) {
        Write-Verbose "NSG rule '$Name' already present, skipping."
        return
    }
    Write-Verbose "Adding NSG rule '$Name' (priority $Priority, TCP port $DestPort)"
    az network nsg rule create `
        --name $Name `
        --nsg-name $nsgName `
        --priority $Priority `
        --resource-group $rgName `
        --access Allow `
        --source-address-prefixes '*' `
        --source-port-ranges '*' `
        --direction Inbound `
        --protocol Tcp `
        --destination-port-ranges $DestPort `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az network nsg rule create '$Name' failed." }
}

Add-NsgRuleIfAbsent -Name 'AllowSshInbound'   -Priority 1000 -DestPort '22'
Add-NsgRuleIfAbsent -Name 'AllowHttpInbound'  -Priority 1010 -DestPort '80'
Add-NsgRuleIfAbsent -Name 'AllowHttpsInbound' -Priority 1020 -DestPort '443'

# ---------------------------------------------------------------------------
# 3. Subnet (idempotent), associated with the NSG.
# ---------------------------------------------------------------------------

$existingSubnet = az network vnet subnet show `
    --name $subnetName `
    --vnet-name $vnetName `
    --resource-group $rgName 2>$null | ConvertFrom-Json
if ($existingSubnet) {
    Write-Verbose "Subnet '$subnetName' already present, ensuring NSG association."
    $currentNsgId = $existingSubnet.networkSecurityGroup.id
    $desiredNsgId = (az network nsg show --name $nsgName -g $rgName --query id --output tsv).Trim()
    if ($currentNsgId -ne $desiredNsgId) {
        Write-Verbose "Re-associating NSG '$nsgName' onto subnet '$subnetName' (was: $currentNsgId)"
        az network vnet subnet update `
            --name $subnetName `
            --vnet-name $vnetName `
            --resource-group $rgName `
            --network-security-group $nsgName `
            --output none
        if ($LASTEXITCODE -ne 0) { throw "az network vnet subnet update '$subnetName' failed." }
    } else {
        Write-Verbose "NSG association on '$subnetName' already correct."
    }
} else {
    Write-Verbose "Creating subnet '$subnetName' ($subnetIPv6, $subnetIPv4)"
    az network vnet subnet create `
        --name $subnetName `
        --address-prefix $subnetIPv6 $subnetIPv4 `
        --resource-group $rgName `
        --vnet-name $vnetName `
        --network-security-group $nsgName `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az network vnet subnet create '$subnetName' failed." }
}

Write-Verbose "Deploy LLM subnet '$subnetName' complete (NSG '$nsgName')."
