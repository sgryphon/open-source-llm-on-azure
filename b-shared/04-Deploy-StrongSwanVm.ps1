#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy server into Azure running Eclipse Leshan LwM2M server, with basic security.

.NOTES
  This creates a server in your Azure subscription and deploys an Eclipse Leshan LwM2M
  server, with HTTPS security behind a Caddy proxy, and with web access behind
  basic security.

  The server uses the landing zone private network defined in `azure-landing`.

  By default it has a public IPv6 and a DNS entry with a unique identifier based on
  your subscription prefix: "lwm2m-<prefix>-dev.australiaeast.cloudapp.azure.com"

  IPv4 is also enabled by default (but can be disabled), and has the prefix:
  "lwm2m-<prefix>-dev-ipv4.australiaeast.cloudapp.azure.com"

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
   ./deploy-leshan.ps1 -WebPassword YourSecretPassword
#>
[CmdletBinding()]
param (
    ## Basic authentication password for web access
    [string]$WebPassword = $ENV:DEPLOY_WEB_PASSWORD,
    ## Purpose prefix
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## Identifier for the organisation (or subscription) to make global names unique.
    [string]$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
    ## Instance number uniquifier
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001',
    ## VM size, default is Standard_D2s_v6
    [string]$VmSize = $ENV:DEPLOY_VM_SIZE ?? 'Standard_D2s_v6',
    ## Linux admin account name (authentication via SSH)
    [string]$AdminUsername = $ENV:DEPLOY_ADMIN_USERNAME ?? 'admin',
    ## Static server address suffix
    [string]$PrivateIpSuffix = $ENV:DEPLOY_PRIVATE_IP ?? "100d",
    ## Auto-shutdown time in UTC, default 0900 is 19:00 in Brisbane
    [string]$ShutdownUtc = $ENV:DEPLOY_SHUTDOWN_UTC ?? '0900',
    ## Email to send auto-shutdown notification to (optional)
    [string]$ShutdownEmail = $ENV:DEPLOY_SHUTDOWN_EMAIL ?? '',
    ## Add a public IPv4 (if needed)
    [switch]$AddPublicIpv4 = $true
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))"
$VmSize = $ENV:DEPLOY_VM_SIZE ?? 'Standard_D2s_v6'
$AdminUsername = $ENV:DEPLOY_ADMIN_USERNAME ?? 'iotadmin'
$PrivateIpSuffix = $ENV:DEPLOY_PRIVATE_IP ?? "100d"
$ShutdownUtc = $ENV:DEPLOY_SHUTDOWN_UTC ?? '0900'
$ShutdownEmail = $ENV:DEPLOY_SHUTDOWN_UTC ?? ''
$AddPublicIpv4 = $true
#>

if (!$WebPassword) { throw 'You must supply a value for -WebPassword or set environment variable DEPLOY_WEB_PASSWORD' }

$ErrorActionPreference="Stop"

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying scripts for environment '$Environment' in subscription '$SubscriptionId'$($AddPublicIpv4 ? ' with IPv4' : '')"

# Following standard naming conventions from Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming
# With an additional organisation or subscription identifier (after app name) in global names to make them unique 

$appName = 'strongswan'
$rgName = "rg-$appName-$Environment-001".ToLowerInvariant()
# Copy location details from the RG
$rg = az group show --name $rgName | ConvertFrom-Json

$vnetName = "vnet-$Purpose-hub-$Region-$Instance".ToLowerInvariant()
$gatewayNsgName = "nsg-$Purpose-gateway-$Environment-001".ToLowerInvariant()
$gatewaySubnetName = "snet-$Purpose-gateway-$Environment-$($rg.location)-001".ToLowerInvariant()

$vmName = "vm$($appName)$($Instance)".ToLowerInvariant()
$vmOsDisk = "osdiskvm$($appName)$($Instance)".ToLowerInvariant()
$pipDnsName = "$appName-$OrgId-$Environment".ToLowerInvariant()
$pipName = "pip-$vmName-$Environment-$($rg.location)-$Instance".ToLowerInvariant()
$nicName = "nic-01-$vmName-$Environment-$Instance".ToLowerInvariant()
$ipcName = "ipc-01-$vmName-$Environment-$Instance".ToLowerInvariant()
#$dataDiskSize = 20

$vmImage = 'UbuntuLTS'

# Following standard tagging conventions from  Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging

$TagDictionary = [ordered]@{
    DataClassification = 'Non-business'
    Criticality        = 'Low'
    BusinessUnit       = $Purpose
    ApplicationName    = $appName
    Env                = $Environment
}

# Convert dictionary to tags format used by Azure CLI create command
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

# Get network subnets, and generate addresses

$gatewaySnet = az network vnet subnet show --name $gatewaySubnetName -g $rgName --vnet-name $vnetName | ConvertFrom-Json

if (!$gatewaySnet) { throw "Landing zone network subnet $gatewaySubnetName not found; see scripts in azure-landing to create" }

# Assumption: ends in "/64"
$gatewayUlaPrefix = $gatewaySnet.addressPrefixes | Where-Object { $_.StartsWith('fd') } | Select-Object -First 1
$vmIpAddress = "$($gatewayUlaPrefix.Substring(0, $gatewayUlaPrefix.Length - 3))$PrivateIpSuffix"

# Assumption: ends in "/27"
# TODO: Correctly handle prefix bits and add unique address
$prefixLength = 27
$subnetBits = 32 - $prefixLength
$subnetIdMask = [Math]::Pow(2, 8 - $subnetBits) - 1
$gatewaySubnetIPv4 = "10.$prefixByte.$("0x" + $VnetId -bAnd 0xFF).$(("0x" + $SubnetId -bAnd $subnetIdMask) -shl $subnetBits)/$prefixLength"

$gatewayIPv4Prefix = $gatewaySnet.addressPrefixes | Where-Object { $_.StartsWith('10.') } | Select-Object -First 1
$privateIPv4Suffix = [int]"0x$($PrivateIpSuffix.Substring($PrivateIpSuffix.Length -2))"
$vmIPv4 = "$($gatewayIPv4Prefix.Substring(0, $gatewayIPv4Prefix.Length - 4))$privateIPv4Suffix"

# Create

Write-Verbose "Adding Network security group rule 'AllowLwM2M' for port 5683, 5684 to $gatewayNsgName"
az network nsg rule create --name AllowLwM2M `
                           --nsg-name $gatewayNsgName `
                           --priority 2100 `
                           --resource-group $rgName `
                           --access Allow `
                           --source-address-prefixes "*" `
                           --source-port-ranges "*" `
                           --direction Inbound `
                           --protocol Udp `
                           --destination-port-ranges 5683 5684

Write-Verbose "Creating Public IP addresses $pipName (DNS $pipDnsName)"
az network public-ip create `
  --name $pipName  `
  --dns-name $pipDnsName `
  --resource-group $rgName `
  --location $rg.location `
  --sku Standard  `
  --allocation-method static  `
  --version IPv6 `
  --tags $tags

# Azure only supports dual stack; primary NIC IP config must be IPv4

Write-Verbose "Creating Network interface controller $nicName (required IPv4 $vmIPv4)"
az network nic create `
  --name $nicName `
  --resource-group $rgName `
  --subnet $gatewaySnet.Id `
  --private-ip-address $vmIPv4 `
  --tags $tags

Write-Verbose "Adding NIC IP Config $ipcName ($vmIpAddress, $pipName) to $nicName"
az network nic ip-config create `
  --name $ipcName `
  --nic-name $nicName  `
  --resource-group $rgName `
  --subnet $gatewaySnet.Id `
  --private-ip-address $vmIpAddress `
  --private-ip-address-version IPv6 `
  --public-ip-address $pipName

$hostNames = $(az network public-ip show --name $pipName --resource-group $rgName --query dnsSettings.fqdn --output tsv)

if ($AddPublicIpv4) {
  $pipv4Name = "pipv4-$vmName-$Environment-$($rg.location)-001".ToLowerInvariant()
  $pipv4DnsName = "lwm2m-$OrgId-$Environment-ipv4".ToLowerInvariant()

  Write-Verbose "Creating Public IPv4 addresses $pipv4Name (DNS $pipv4DnsName)"
  az network public-ip create `
    --name $pipv4Name  `
    --dns-name $pipv4DnsName `
    --resource-group $rgName `
    --location $rg.location  `
    --sku Standard  `
    --allocation-method static  `
    --version IPv4 `
    --tags $tags

  # the auto-created config name is ipconfig1
  az network nic ip-config update `
    --name 'ipconfig1' `
    --nic-name $nicName `
    -g $rgName `
    --public-ip-address $pipv4Name

  $hostNames = "$hostNames, $(az network public-ip show --name $pipv4Name --resource-group $rgName --query dnsSettings.fqdn --output tsv)"
}
   
Write-Verbose "Configurating cloud-init.txt~ file with host names: $hostNames"
(Get-Content -Path (Join-Path $PSScriptRoot 'data' 'strongswan-cloud-init.txt') -Raw) `
  -replace '#INIT_HOST_NAMES#',$hostNames `
  -replace '#INIT_PASSWORD_INPUT#',$WebPassword `
  | Set-Content -Path (Join-Path $PSScriptRoot 'temp' 'strongswan-cloud-init.txt~')

Write-Verbose "Creating Virtual machine $vmName (size $vmSize)"
az vm create `
    --resource-group $rgName `
    --name $vmName `
    --size $VmSize `
    --image $vmImage `
    --os-disk-name $vmOsDisk `
    --admin-username $AdminUsername `
    --generate-ssh-keys `
    --nics $nicName `
    --public-ip-sku Standard `
    --custom-data (Join-Path $PSScriptRoot 'temp' 'cloud-init.txt~') `
    --tags $tags

#    --data-disk-caching None `
#    --data-disk-sizes-gb $DataDiskSize `

if ($ShutdownUtc) {
  if ($ShutdownEmail) {
    az vm auto-shutdown -g $rgName -n $vmName --time $ShutdownUtc --email $ShutdownEmail
  } else {
    az vm auto-shutdown -g $rgName -n $vmName --time $ShutdownUtc
  }
}

Write-Verbose "Virtual machine created"

$vm = (az vm show --name $vmName -g $rgName -d) | ConvertFrom-Json
$vm | Format-List name, fqdns, publicIps, privateIps, location, hardwareProfile

Write-Verbose "Deployment Complete"
# ssh iotadmin@lwm2m-0xacc5-dev.australiaeast.cloudapp.azure.com