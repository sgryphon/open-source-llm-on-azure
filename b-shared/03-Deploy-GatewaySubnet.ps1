#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy gateway subnet intp hub network.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * Network Security Group
    * Subnet `rg-llm-core-001`

  Addresses are derived deterministically with an IPv6 ULA Global ID 10-hex-character
  SHA256 prefix of the subscription ID. IPv4 has a 10.x network using the first byte.
  
  This gives subscriptions unique but consistent ranges.

.NOTES
  This creates a core network in your Azure subscription.

  The network is dual stack with an IPv6 /56 Unique Local Address allocation,
  using a default Global ID based on a consistent unique hash of the
  subscription ID, with a default vnet ID, fdxx:xxxx:xxxx:yy00::/56.

  The -UlaGlobalId and -VnetId can also be passed in as parameters.
  For more information on ULAs see https://en.wikipedia.org/wiki/Unique_local_address

  IPv4 addresses use the first byte of the ULA global ID, and the vnet ID to
  generate a 10.x.y.0/24 virtual network.

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
   ./01-init-core-rg.ps1
#>
[CmdletBinding()]
param (
    ## Purpose prefix
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## The Azure region where the resource is deployed.
    [string]$Region = $ENV:DEPLOY_REGION ?? 'australiaeast',
    ## Instance number uniquifier
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001',
    ## Ten character IPv6 Unique Local Address GlobalID to use (default hash of subscription ID)
    [string]$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10),
    ## Two character IPv6 Unique Local Address vnet ID to use for core subnet (default 01)
    [string]$VnetId = $ENV:DEPLOY_HUB_VNET_ID ?? ("01"),
    ## Two character IPv6 Unique Local Address subnet ID to use for gateway subnet (default 00)
    [string]$SubnetId = $ENV:DEPLOY_GATEWAY_SUBNET_ID ?? ("00")
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$Region = $ENV:DEPLOY_REGION ?? 'australiaeast'
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10)
$VnetId = $ENV:DEPLOY_HUB_VNET_ID ?? ("01")
$SubnetId = $ENV:DEPLOY_GATEWAY_SUBNET_ID ?? ("00")
#>

$ErrorActionPreference="Stop"

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying $Purpose gateway subnet in subscription '$SubscriptionId'"

# Following standard naming conventions from Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming
# With an additional organisation or subscription identifier (after app name) in global names to make them unique 

$rgName = "rg-$Purpose-core-$Instance".ToLowerInvariant()
# Copy location details from the RG
$rg = az group show --name $rgName | ConvertFrom-Json

$vnetName = "vnet-$Purpose-hub-$Region-$Instance".ToLowerInvariant()
$gatewayNsgName = "nsg-$Purpose-gateway-$Environment-001".ToLowerInvariant()
$gatewaySubnetName = "snet-$Purpose-gateway-$Environment-$($rg.location)-001".ToLowerInvariant()

# Landing zone templates have a VNet RG, with one network, and four subnets:
# GatewaySubnet (.0/26), AzureFirewallSubnet (.64/26),
# JumpboxSubnet (.128/26) - with Jumpbox-NSG (allow inbound vnet-vnet, loadbal-any; outbound vnet-vnet, any-internet),
# CoreSubnet (.4.0/22) - with Core-NSG (allow inbound vnet-vnet, loadbal-any; outbound vnet-vnet, any-internet)

# Global will default to unique value per subscription
$prefix = "fd$($UlaGlobalId.Substring(0, 2)):$($UlaGlobalId.Substring(2, 4)):$($UlaGlobalId.Substring(6))"
$vnetAddress = [IPAddress]"$($prefix):$($VnetId)00::"
$vnetIpPrefix = "$vnetAddress/56"

$gatewaySubnetAddress = [IPAddress]"$($prefix):$($VnetId)$($SubnetId)::"
$gatewaySubnetIpPrefix = "$gatewaySubnetAddress/64"

# Azure only supports dual-stack (not single stack IPv6)
# "At least one IPv4 ipConfiguration is required for an IPv6 ipConfiguration on the network interface"

# Use the first byte of the ULA Global ID, and the vnet ID (as decimal)
$prefixByte = [int]"0x$($UlaGlobalId.Substring(0, 2))"
$vnetIPv4 = "10.$prefixByte.$($VnetId -bAnd 0xFF).0/24"

# Use `/27` subnet, inside `/24` vnet, allowing 3 bits for subnet (8 per vnet), each with 5 bits for 32 addresses
$prefixLength = 27
$subnetBits = 32 - $prefixLength
$subnetIdMask = [Math]::Pow(2, 8 - $subnetBits) - 1
$gatewaySubnetIPv4 = "10.$prefixByte.$("0x" + $VnetId -bAnd 0xFF).$(("0x" + $SubnetId -bAnd $subnetIdMask) -shl $subnetBits)/$prefixLength"

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

# Create

Write-Verbose "Creating core network security group $gatewayNsgName"
az network nsg create --name $gatewayNsgName -g $rgName -l $rg.location --tags $tags

Write-Verbose "Adding Network security group rule 'AllowSSH' for port 22 to $gatewayNsgName"
az network nsg rule create --name AllowSSH `
                           --nsg-name $gatewayNsgName `
                           --priority 1000 `
                           --resource-group $rgName `
                           --access Allow `
                           --source-address-prefixes "*" `
                           --source-port-ranges "*" `
                           --direction Inbound `
                           --destination-port-ranges 22

Write-Verbose "Adding Network security group rule 'AllowICMP' for ICMP to $gatewayNsgName"
az network nsg rule create --name AllowICMPv4 `
                           --nsg-name $gatewayNsgName `
                           --priority 1001 `
                           --resource-group $rgName `
                           --access Allow `
                           --source-address-prefixes "*" `
                           --direction Inbound `
                           --destination-port-ranges "*" `
                           --protocol Icmp

# Can't create ICMPv6 via API.
# If you create a rule, then you can update it via the UI.

# az network nsg rule create --name AllowICMPv6 `
#                            --nsg-name $gatewayNsgName `
#                            --priority 1002 `
#                            --resource-group $rgName `
#                            --access Allow `
#                            --source-address-prefixes "*" `
#                            --direction Inbound `
#                            --destination-port-ranges "*" `
#                            --protocol Icmp

# Viewing the rule has Protocol = "ICMPv6"
# az network nsg rule show --nsg-name $gatewayNsgName --resource-group $rgName -n "AllowICMPv6"    

# $icmpv6 = @{
#     properties = @{
#         priority                 = 1002
#         access                   = 'Allow'
#         direction                = 'Inbound'
#         protocol                 = 'ICMPv6'
#     }
# } | ConvertTo-Json -Depth 5
# az rest `
#   --method put `
#   --url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.Network/networkSecurityGroups/$gatewayNsgName/securityRules/AllowICMPv6?api-version=2023-09-01" `
#   --headers "Content-Type=application/json" `
#   --body $icmpv6

# But fails parsing the protocol
# Bad Request({"error":{"code":"InvalidRequestContent","message":"The request content was invalid and could not be deserialized: 'Error parsing Infinity value. Path 'properties.protocol', line 4, position 15.'."}})
                           
Write-Verbose "Adding Network security group rule 'AllowHTTP' for port 80, 443 to $gatewayNsgName"
az network nsg rule create --name AllowHTTP `
                           --nsg-name $gatewayNsgName `
                           --priority 1003 `
                           --resource-group $rgName `
                           --access Allow `
                           --source-address-prefixes "*" `
                           --source-port-ranges "*" `
                           --direction Inbound `
                           --destination-port-ranges 80 443

# Check rules
# az network nsg rule list --nsg-name $nsgDmzName --resource-group $rgName

Write-Verbose "Creating core subnet $gatewaySubnetName ($gatewaySubnetIpPrefix, $gatewaySubnetIPv4)"
az network vnet subnet create --name $gatewaySubnetName `
                              --address-prefix $gatewaySubnetIpPrefix $gatewaySubnetIPv4 `
                              --resource-group $rgName `
                              --vnet-name $vnetName `
                              --network-security-group $gatewayNsgName

Write-Verbose "Deploy gateway subnet $rgName complete"
