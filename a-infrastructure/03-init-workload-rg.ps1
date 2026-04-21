#!/usr/bin/env pwsh

<#
.SYNOPSIS
  Initialise a workload resource group + VNet and peer it with gateway and shared.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * Resource group  `rg-llm-workload-<env>-001`
    * Virtual network `vnet-llm-workload-<env>-<location>-001`, dual-stack
    * Peering `peer-workload-<env>-to-gateway`   (workload VNet side)   -- allow-forwarded-traffic true
    * Peering `peer-gateway-to-workload-<env>`   (gateway VNet side)    -- allow-forwarded-traffic true
    * Peering `peer-workload-<env>-to-shared`    (workload VNet side)   -- vnet-access only
    * Peering `peer-shared-to-workload-<env>`    (shared VNet side)     -- vnet-access only

  Peerings are guarded with `az network vnet peering show` so the script is
  re-runnable.

  Addresses are derived deterministically from `-UlaGlobalId` (default = the
  10-hex-character SHA256 prefix of the current subscription ID, matching the
  IOT reference).

  Assumes `01-init-shared-rg.ps1` and `02-init-gateway-rg.ps1` have already
  been run with the same `-UlaGlobalId` and `-Location`.

.NOTES
  Requirements:
    * PowerShell 7+ (https://github.com/PowerShell/PowerShell)
    * Azure CLI      (https://docs.microsoft.com/en-us/cli/azure/)
    * `az login` with Contributor on the target subscription

.EXAMPLE
    az login
    az account set --subscription <subscription id>
    $VerbosePreference = 'Continue'
    ./03-init-workload-rg.ps1 -Environment Dev
#>
[CmdletBinding()]
param (
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    [string]$Location    = $ENV:DEPLOY_LOCATION    ?? 'australiaeast',
    [string]$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID   ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10)
)

$ErrorActionPreference = 'Stop'

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Initialising workload RG for environment '$Environment' in subscription '$SubscriptionId'"
Write-Verbose "UlaGlobalId = $UlaGlobalId"

# ---------------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------------
$envLower      = $Environment.ToLowerInvariant()
$locationLower = $Location.ToLowerInvariant()

$workloadRgName   = "rg-llm-workload-$envLower-001"
$workloadVnetName = "vnet-llm-workload-$envLower-$locationLower-001"

$gatewayRgName   = 'rg-llm-gateway-001'
$gatewayVnetName = "vnet-llm-gateway-$locationLower-001"

$sharedRgName    = 'rg-llm-shared-001'
$sharedVnetName  = "vnet-llm-shared-$locationLower-001"

# ---------------------------------------------------------------------------
# Address derivation (workload: 0300 / .3. per tasks.md 4.2)
# ---------------------------------------------------------------------------
$prefix     = "fd$($UlaGlobalId.Substring(0, 2)):$($UlaGlobalId.Substring(2, 4)):$($UlaGlobalId.Substring(6))"
$prefixByte = [int]"0x$($UlaGlobalId.Substring(0, 2))"

$workloadVnetId     = '0300'
$workloadVnetIdByte = [int]"0x$workloadVnetId" -bAnd 0xFF

$workloadAddress = [IPAddress]"$($prefix):$workloadVnetId::"
$workloadIpv6    = "$workloadAddress/64"
$workloadIpv4    = "10.$prefixByte.$workloadVnetIdByte.0/24"
Write-Verbose "Workload prefixes: $workloadIpv6, $workloadIpv4"

# ---------------------------------------------------------------------------
# CAF tags
# ---------------------------------------------------------------------------
$TagDictionary = [ordered]@{
    WorkloadName       = 'llm'
    ApplicationName    = 'llm'
    DataClassification = 'Non-business'
    Criticality        = 'Low'
    BusinessUnit       = 'IT'
    Env                = $Environment
}
$tags = $TagDictionary.Keys | ForEach-Object { "$_=$($TagDictionary[$_])" }

# ---------------------------------------------------------------------------
# Create workload RG + VNet (idempotent)
# ---------------------------------------------------------------------------
Write-Verbose "Creating resource group $workloadRgName in $Location"
az group create `
    --name $workloadRgName `
    --location $Location `
    --tags $tags `
    --output none

Write-Verbose "Creating virtual network $workloadVnetName ($workloadIpv6, $workloadIpv4)"
az network vnet create `
    --name $workloadVnetName `
    --resource-group $workloadRgName `
    --location $Location `
    --address-prefixes $workloadIpv6 $workloadIpv4 `
    --tags $tags `
    --output none

# ---------------------------------------------------------------------------
# Resolve remote VNet resource IDs
# ---------------------------------------------------------------------------
$workloadVnetResourceId = az network vnet show --name $workloadVnetName --resource-group $workloadRgName --query id --output tsv
$gatewayVnetResourceId  = az network vnet show --name $gatewayVnetName  --resource-group $gatewayRgName  --query id --output tsv
$sharedVnetResourceId   = az network vnet show --name $sharedVnetName   --resource-group $sharedRgName   --query id --output tsv

# ---------------------------------------------------------------------------
# Helper: idempotent peering create
# ---------------------------------------------------------------------------
function New-PeeringIfMissing {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$VNetName,
        [Parameter(Mandatory)][string]$RemoteVNetId,
        [switch]$AllowForwardedTraffic
    )
    Write-Verbose "Checking peering $Name on $VNetName"
    $existing = az network vnet peering show `
        --name $Name `
        --resource-group $ResourceGroup `
        --vnet-name $VNetName `
        --output tsv 2>$null
    if ($existing) {
        Write-Verbose "Peering $Name already exists; skipping."
        return
    }

    Write-Verbose "Creating peering $Name on $VNetName (forwarded-traffic=$($AllowForwardedTraffic.IsPresent))"
    $args = @(
        'network','vnet','peering','create',
        '--name', $Name,
        '--resource-group', $ResourceGroup,
        '--vnet-name', $VNetName,
        '--remote-vnet', $RemoteVNetId,
        '--allow-vnet-access', 'true',
        '--output', 'none'
    )
    if ($AllowForwardedTraffic) {
        $args += @('--allow-forwarded-traffic','true')
    }
    az @args
}

# ---------------------------------------------------------------------------
# Workload <-> Gateway (forwarded-traffic true on both halves)
# ---------------------------------------------------------------------------
New-PeeringIfMissing `
    -Name "peer-workload-$envLower-to-gateway" `
    -ResourceGroup $workloadRgName `
    -VNetName $workloadVnetName `
    -RemoteVNetId $gatewayVnetResourceId `
    -AllowForwardedTraffic

New-PeeringIfMissing `
    -Name "peer-gateway-to-workload-$envLower" `
    -ResourceGroup $gatewayRgName `
    -VNetName $gatewayVnetName `
    -RemoteVNetId $workloadVnetResourceId `
    -AllowForwardedTraffic

# ---------------------------------------------------------------------------
# Workload <-> Shared (vnet-access only, forwarded-traffic defaults to false)
# ---------------------------------------------------------------------------
New-PeeringIfMissing `
    -Name "peer-workload-$envLower-to-shared" `
    -ResourceGroup $workloadRgName `
    -VNetName $workloadVnetName `
    -RemoteVNetId $sharedVnetResourceId

New-PeeringIfMissing `
    -Name "peer-shared-to-workload-$envLower" `
    -ResourceGroup $sharedRgName `
    -VNetName $sharedVnetName `
    -RemoteVNetId $workloadVnetResourceId

Write-Verbose 'Workload RG + VNet + peerings complete.'
