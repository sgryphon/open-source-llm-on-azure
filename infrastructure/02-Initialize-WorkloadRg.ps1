#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy workload resource group and network into Azure.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * Resource group `rg-llm-workload-dev-001`
    * Virtual network `vnet-llm-workload-dev-australiaeast-001`, dual-stack
    * Two-way peering `peer-llm-workload-dev-to-hub` and `peer-llm-hub-to-workload-dev`

  Addresses are derived deterministically with an IPv6 ULA Global ID 10-hex-character
  SHA256 prefix of the subscription ID. IPv4 has a 10.x network using the first byte.

.NOTES
  This creates a worload network in your Azure subscription.

  The network is dual stack with an IPv6 /56 Unique Local Address allocation,
  using a default Global ID based on a consistent unique hash of the
  subscription ID, with a default vnet ID, fdxx:xxxx:xxxx:yy00::/56.

  The -UlaGlobalId and -VnetId can also be passed in as parameters.
  For more information on ULAs see https://en.wikipedia.org/wiki/Unique_local_address

  IPv4 addresses use the first byte of the ULA global ID, and the vnet ID to
  generate a 10.x.y.0/20 virtual network.

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
   ./02-Initialize-WorkloadRg.ps1
#>
[CmdletBinding()]
param (
    ## Purpose prefix
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Workload prefix
    [string]$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## The Azure region where the resource is deployed.
    [string]$Region = $ENV:DEPLOY_REGION ?? 'australiaeast',
    ## Instance number uniquifier
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001',
    ## Ten character IPv6 Unique Local Address GlobalID to use (default hash of subscription ID)
    [string]$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10),
    ## Two character IPv6 Unique Local Address vnet ID to use for workload subnet (default 02)
    [string]$VnetId = $ENV:DEPLOY_WORKLOAD_VNET_ID ?? ("02")
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload',
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$Region = $ENV:DEPLOY_REGION ?? 'australiaeast'
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10)
$VnetId = $ENV:DEPLOY_WORKLOAD_VNET_ID ?? ("02")
#>

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Initialising $Purpose $Workload $Environment resource group in subscription '$SubscriptionId'"

# Following standard naming conventions from Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming
# With an additional organisation or subscription identifier (after app name) in global names to make them unique 

$rgName = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$vnetName = "vnet-$Purpose-$Workload-$Environment-$Region-$Instance".ToLowerInvariant()

$coreRgName = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$hubVnetName = "vnet-$Purpose-hub-$Region-$Instance".ToLowerInvariant()

# Landing zone templates have a VNet RG, with one network, and four subnets:
# GatewaySubnet (.0/26), AzureFirewallSubnet (.64/26),
# JumpboxSubnet (.128/26) - with Jumpbox-NSG (allow inbound vnet-vnet, loadbal-any; outbound vnet-vnet, any-internet),
# CoreSubnet (.4.0/22) - with Core-NSG (allow inbound vnet-vnet, loadbal-any; outbound vnet-vnet, any-internet)

# Global will default to unique value per subscription
$prefix = "fd$($UlaGlobalId.Substring(0, 2)):$($UlaGlobalId.Substring(2, 4)):$($UlaGlobalId.Substring(6))"
$vnetAddress = [IPAddress]"$($prefix):$($VnetId)00::"
$vnetIpPrefix = "$vnetAddress/56"

# Azure only supports dual-stack (not single stack IPv6)
# "At least one IPv4 ipConfiguration is required for an IPv6 ipConfiguration on the network interface"

# Use the first byte of the ULA Global ID, and the vnet ID (as decimal)
$prefixByte = [int]"0x$($UlaGlobalId.Substring(0, 2))"
$decVnet = [int]("0x$VnetId" -bAnd 0xf) -shl 4
$vnetIPv4 = "10.$prefixByte.$decVnet.0/20"

# Following standard tagging conventions from  Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging

$TagDictionary = [ordered]@{
    WorkloadName       = $Workload
    DataClassification = 'Non-business'
    Criticality        = 'Low'
    BusinessUnit       = $Purpose
    Env                = $Environment
}

# Convert dictionary to tags format used by Azure CLI create command
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

# Create

Write-Verbose "Creating resource group $rgName"
az group create --name $rgName -l $Region --tags $tags
if ($LASTEXITCODE -ne 0) { throw "az group create failed for '$rgName'" }

Write-Verbose "Creating virtual network $vnetName ($vnetIpPrefix, $vnetIPv4)"
az network vnet create --name $vnetName `
                       --resource-group $rgName `
                       --address-prefixes $vnetIpPrefix $vnetIPv4 `
                       --location $Region `
                       --tags $tags

# Peering

function NewPeeringIfMissing (
        [string]$peerName,
        [string]$peerRgName, 
        [string]$peerVnetName, 
        [string]$remoteRgName,
        [string]$remoteVnetName,
        [boolean]$allowForwardedTraffic
    )
{
    Write-Verbose "Checking peering $Name on $VNetName"
    $existing = az network vnet peering show `
        --name $peerName `
        --resource-group $peerRgName `
        --vnet-name $peerVnetName `
        --output tsv 2>$null
    if ($existing) {
        Write-Verbose "Peering $Name already exists; skipping."
        return
    }

    $remoteVnetResourceId = az network vnet show --name $remoteVnetName --resource-group $remoteRgName --query id --output tsv

    Write-Verbose "Creating peering $peerName on $peerVnetName to $remoteVnetName (forwarded-traffic=$($AllowForwardedTraffic.IsPresent))"
    $args = @(
        'network','vnet','peering','create',
        '--name', $peerName,
        '--resource-group', $peerRgName,
        '--vnet-name', $peerVnetName,
        '--remote-vnet', $remoteVnetResourceId,
        '--allow-vnet-access', 'true',
        '--output', 'none'
    )
    if ($allowForwardedTraffic) {
        $args += @('--allow-forwarded-traffic','true')
    }
    az @args
}

# Peering Workload <-> Hub (forwarded-traffic true on both halves)
$peerVnetToHubName = "peer-$Purpose-$Workload-$Environment-to-hub".ToLowerInvariant()
$peerHubToVnetName = "peer-$Purpose-hub-to-$Workload-$Environment".ToLowerInvariant()

NewPeeringIfMissing $peerVnetToHubName $rgName $vnetName $coreRgName $hubVnetName $true
NewPeeringIfMissing $peerHubToVnetName $coreRgName $hubVnetName $rgName $vnetName $true

Write-Verbose "Initialise $rgName complete"
