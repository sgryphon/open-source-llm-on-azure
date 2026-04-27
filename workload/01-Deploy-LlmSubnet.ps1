#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy the workload subnet and its NSG into the existing workload VNet.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * Network Security Group `nsg-llm-workload-dev-001

  Adds a subnet `subnet-llm-workload-dev-australiaeast-001` to the hub vnet. 

  Addresses are derived deterministically with an IPv6 ULA Global ID 10-hex-character
  SHA256 prefix of the subscription ID. IPv4 has a 10.x network using the first byte.
  
  This gives subscriptions unique but consistent ranges.

.NOTES
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
   ./workload/01-Deploy-LlmSubnet.ps1
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
    ## Two-character subnet ID inside the workload VNet (default `00` for the LLM/vLLM subnet).
    [string]$SubnetId = $ENV:DEPLOY_WORKLOAD_SUBNET_ID ?? '00'
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
    throw "Resource group '$rgName' not found."
}
$vnet = az network vnet show --name $vnetName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $vnet) {
    throw "Workload VNet '$vnetName' not found in '$rgName'."
}

# Derive subnet prefixes deterministically from UlaGlobalId, WorkloadVnetId, SubnetId.
$prefix          = "fd$($UlaGlobalId.Substring(0, 2)):$($UlaGlobalId.Substring(2, 4)):$($UlaGlobalId.Substring(6))"
$subnetIPv6Addr  = [IPAddress]"$($prefix):$($WorkloadVnetId)$($SubnetId)::"
$subnetIPv6      = "$subnetIPv6Addr/64"

# Use the first byte of the ULA Global ID, and the vnet ID (as decimal)
$prefixByte = [int]"0x$($UlaGlobalId.Substring(0, 2))"
$decVnet = [int]("0x$WorkloadVnetId" -bAnd 0xf) -shl 4
$decSubnet = [int]("0x$SubnetId" -bAnd 0xf)

$subnetIPv4 = "10.$prefixByte.$($decVnet + $decSubnet).0/24"

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
