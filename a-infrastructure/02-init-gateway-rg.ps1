#!/usr/bin/env pwsh

<#
.SYNOPSIS
  Initialise the gateway resource group and VNet, and peer it with the shared VNet.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * Resource group  `rg-llm-gateway-001`
    * Virtual network `vnet-llm-gateway-<location>-001`, dual-stack (IPv4 + IPv6 ULA)
    * Peering `peer-shared-to-gateway`  on the shared VNet
    * Peering `peer-gateway-to-shared`  on the gateway VNet

  Both peerings are created with `--allow-vnet-access true` and
  `--allow-forwarded-traffic true` so that a future VPN landing in the gateway
  VNet can transit to the spokes.

  Peerings are guarded by `az network vnet peering show` so the script can be
  re-run safely.

  Addresses are derived deterministically from `-UlaGlobalId` (default = the
  10-hex-character SHA256 prefix of the current subscription ID, matching the
  IOT reference project).

  This script assumes `01-init-shared-rg.ps1` has already been run with the
  same `-UlaGlobalId` and `-Location`.

.NOTES
  Requirements:
    * PowerShell 7+ (https://github.com/PowerShell/PowerShell)
    * Azure CLI      (https://docs.microsoft.com/en-us/cli/azure/)
    * `az login` with Contributor on the target subscription

.EXAMPLE
    az login
    az account set --subscription <subscription id>
    $VerbosePreference = 'Continue'
    ./02-init-gateway-rg.ps1
#>
[CmdletBinding()]
param (
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    [string]$Location    = $ENV:DEPLOY_LOCATION    ?? 'australiaeast',
    [string]$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID   ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10)
)

$ErrorActionPreference = 'Stop'

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Initialising gateway RG for environment '$Environment' in subscription '$SubscriptionId'"
Write-Verbose "UlaGlobalId = $UlaGlobalId"

# ---------------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------------
$locationLower = $Location.ToLowerInvariant()

$gatewayRgName   = 'rg-llm-gateway-001'
$gatewayVnetName = "vnet-llm-gateway-$locationLower-001"

$sharedRgName   = 'rg-llm-shared-001'
$sharedVnetName = "vnet-llm-shared-$locationLower-001"

# ---------------------------------------------------------------------------
# Address derivation (per tasks.md 3.2 — same /64 and /24 as shared)
# ---------------------------------------------------------------------------
$prefix     = "fd$($UlaGlobalId.Substring(0, 2)):$($UlaGlobalId.Substring(2, 4)):$($UlaGlobalId.Substring(6))"
$prefixByte = [int]"0x$($UlaGlobalId.Substring(0, 2))"

$gatewayVnetId     = '0100'
$gatewayVnetIdByte = [int]"0x$gatewayVnetId" -bAnd 0xFF

$gatewayAddress = [IPAddress]"$($prefix):$gatewayVnetId::"
$gatewayIpv6    = "$gatewayAddress/64"
$gatewayIpv4    = "10.$prefixByte.$gatewayVnetIdByte.0/24"
Write-Verbose "Gateway prefixes: $gatewayIpv6, $gatewayIpv4"

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
# Create gateway RG + VNet (idempotent)
# ---------------------------------------------------------------------------
Write-Verbose "Creating resource group $gatewayRgName in $Location"
az group create `
    --name $gatewayRgName `
    --location $Location `
    --tags $tags `
    --output none

Write-Verbose "Creating virtual network $gatewayVnetName ($gatewayIpv6, $gatewayIpv4)"
az network vnet create `
    --name $gatewayVnetName `
    --resource-group $gatewayRgName `
    --location $Location `
    --address-prefixes $gatewayIpv6 $gatewayIpv4 `
    --tags $tags `
    --output none

# ---------------------------------------------------------------------------
# Peerings (guarded with `peering show`)
# ---------------------------------------------------------------------------
# Resolve remote VNet resource IDs (required by az network vnet peering create).
$gatewayVnetId = az network vnet show --name $gatewayVnetName --resource-group $gatewayRgName --query id --output tsv
$sharedVnetId  = az network vnet show --name $sharedVnetName  --resource-group $sharedRgName  --query id --output tsv

# peer-shared-to-gateway on the shared VNet
$peerSharedToGateway = 'peer-shared-to-gateway'
Write-Verbose "Checking peering $peerSharedToGateway on $sharedVnetName"
$existing = az network vnet peering show `
    --name $peerSharedToGateway `
    --resource-group $sharedRgName `
    --vnet-name $sharedVnetName `
    --output tsv 2>$null
if (-not $existing) {
    Write-Verbose "Creating peering $peerSharedToGateway (shared -> gateway)"
    az network vnet peering create `
        --name $peerSharedToGateway `
        --resource-group $sharedRgName `
        --vnet-name $sharedVnetName `
        --remote-vnet $gatewayVnetId `
        --allow-vnet-access true `
        --allow-forwarded-traffic true `
        --output none
} else {
    Write-Verbose "Peering $peerSharedToGateway already exists; skipping."
}

# peer-gateway-to-shared on the gateway VNet
$peerGatewayToShared = 'peer-gateway-to-shared'
Write-Verbose "Checking peering $peerGatewayToShared on $gatewayVnetName"
$existing = az network vnet peering show `
    --name $peerGatewayToShared `
    --resource-group $gatewayRgName `
    --vnet-name $gatewayVnetName `
    --output tsv 2>$null
if (-not $existing) {
    Write-Verbose "Creating peering $peerGatewayToShared (gateway -> shared)"
    az network vnet peering create `
        --name $peerGatewayToShared `
        --resource-group $gatewayRgName `
        --vnet-name $gatewayVnetName `
        --remote-vnet $sharedVnetId `
        --allow-vnet-access true `
        --allow-forwarded-traffic true `
        --output none
} else {
    Write-Verbose "Peering $peerGatewayToShared already exists; skipping."
}

Write-Verbose 'Gateway RG + VNet + shared<->gateway peering complete.'
