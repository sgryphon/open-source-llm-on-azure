#!/usr/bin/env pwsh

<#
.SYNOPSIS
  Initialise the shared-services resource group and VNet for the `llm` workload.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * Resource group  `rg-llm-shared-001`
    * Virtual network `vnet-llm-shared-<location>-001`, dual-stack (IPv4 + IPv6 ULA)

  Addresses are derived deterministically from `-UlaGlobalId` (default = a
  10-hex-character SHA256 prefix of the current subscription ID, matching the
  hashing used in the IOT reference project `iot-demo-build`). This gives two
  different subscriptions non-overlapping ranges so they can be safely peered
  later.

  This script does NOT create subnets, NSGs, or peerings; peerings are created
  by scripts 02 and 03.

.NOTES
  Requirements:
    * PowerShell 7+ (https://github.com/PowerShell/PowerShell)
    * Azure CLI      (https://docs.microsoft.com/en-us/cli/azure/)
    * `az login` with Contributor on the target subscription

  Naming follows the Azure Cloud Adoption Framework:
    https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming

  Tagging follows the Azure Cloud Adoption Framework:
    https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging

.EXAMPLE
    az login
    az account set --subscription <subscription id>
    $VerbosePreference = 'Continue'
    ./01-init-shared-rg.ps1
#>
[CmdletBinding()]
param (
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## The Azure region where resources are deployed.
    [string]$Location = $ENV:DEPLOY_LOCATION ?? 'australiaeast',
    ## IPv6 Unique Local Address GlobalID to use (default: hash of subscription ID).
    [string]$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10)
)

$ErrorActionPreference = 'Stop'

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Initialising shared RG for environment '$Environment' in subscription '$SubscriptionId'"
Write-Verbose "UlaGlobalId = $UlaGlobalId"

# ---------------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------------
$locationLower = $Location.ToLowerInvariant()
$envLower      = $Environment.ToLowerInvariant()

# Shared RG / VNet — per tasks.md, no environment token for shared.
$sharedRgName   = 'rg-llm-shared-001'
$sharedVnetName = "vnet-llm-shared-$locationLower-001"

# Gateway names are derived here for reference/peering by later scripts.
$gatewayRgName   = 'rg-llm-gateway-001'
$gatewayVnetName = "vnet-llm-gateway-$locationLower-001"

# ---------------------------------------------------------------------------
# Address derivation (mirrors the IOT reference exactly)
# ---------------------------------------------------------------------------
# UlaGlobalId is 10 hex chars, split as gg gggg gggggg.
$prefix        = "fd$($UlaGlobalId.Substring(0, 2)):$($UlaGlobalId.Substring(2, 4)):$($UlaGlobalId.Substring(6))"
$prefixByte    = [int]"0x$($UlaGlobalId.Substring(0, 2))"

# Shared VNet id is 0100 per tasks.md 2.3.
$sharedVnetId     = '0100'
$sharedVnetIdByte = [int]"0x$sharedVnetId" -bAnd 0xFF

$sharedAddress  = [IPAddress]"$($prefix):$sharedVnetId::"
$sharedIpv6     = "$sharedAddress/64"
$sharedIpv4     = "10.$prefixByte.$sharedVnetIdByte.0/24"

# Reference prefixes for peering / later scripts.
$gatewayVnetId    = '0100'
$gatewayIpv6Ref   = "$([IPAddress]"$($prefix):$gatewayVnetId::")/64"
$gatewayIpv4Ref   = "10.$prefixByte.$([int]"0x$gatewayVnetId" -bAnd 0xFF).0/24"
Write-Verbose "Shared  prefixes: $sharedIpv6, $sharedIpv4"
Write-Verbose "Gateway prefixes (ref): $gatewayIpv6Ref, $gatewayIpv4Ref"

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
# Create resources (idempotent: az group/vnet create return existing resources)
# ---------------------------------------------------------------------------
Write-Verbose "Creating resource group $sharedRgName in $Location"
az group create `
    --name $sharedRgName `
    --location $Location `
    --tags $tags `
    --output none

Write-Verbose "Creating virtual network $sharedVnetName ($sharedIpv6, $sharedIpv4)"
az network vnet create `
    --name $sharedVnetName `
    --resource-group $sharedRgName `
    --location $Location `
    --address-prefixes $sharedIpv6 $sharedIpv4 `
    --tags $tags `
    --output none

Write-Verbose 'Shared RG + VNet initialisation complete.'
