#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy the dual-stack public IPs (IPv6 + IPv4) for the LLM/vLLM VM.

.DESCRIPTION
  Creates, idempotently via Azure CLI, in the workload resource group:

    * IPv6 public IP `pip-llm-vllm-<env>-<region>-001` (Standard SKU, static)
      with DNS label `llm-<orgid>-<env>` resolving to
      `llm-<orgid>-<env>.<region>.cloudapp.azure.com`.
    * IPv4 public IP `pipv4-llm-vllm-<env>-<region>-001` (Standard SKU,
      static) with DNS label `llm-<orgid>-<env>-ipv4` resolving to
      `llm-<orgid>-<env>-ipv4.<region>.cloudapp.azure.com`.

  Both PIPs are static so the DNS label does not drift across stop/start
  cycles. Standard SKU is required to allow a NIC to attach an IPv6 PIP
  on Azure. The IPv6 FQDN is the primary cert subject; the IPv4 FQDN is
  the additional `subjectAltName`.

.NOTES
  Azure does not support single-stack IPv6 — both PIPs are required for
  the NIC the VM is created on. The cert is issued for both names so
  OpenCode can connect over either protocol.

.EXAMPLE

   az login
   az account set --subscription <subscription id>
   $VerbosePreference = 'Continue'
   ./c-workload/04-Deploy-LlmPublicIp.ps1
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
    ## Identifier for the organisation (or subscription) to make global names unique.
    [string]$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
    ## Instance number uniquifier.
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$Region = $ENV:DEPLOY_REGION ?? 'australiaeast'
$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))"
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
#>

$ErrorActionPreference = 'Stop'

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying LLM/vLLM public IPs for '$Environment' in subscription '$SubscriptionId'"

$rgName       = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$rg           = az group show --name $rgName 2>$null | ConvertFrom-Json
if (-not $rg) {
    throw "Workload resource group '$rgName' not found."
}

$pipV6Name    = "pip-$Purpose-vllm-$Environment-$Region-$Instance".ToLowerInvariant()
$pipV4Name    = "pipv4-$Purpose-vllm-$Environment-$Region-$Instance".ToLowerInvariant()
$pipV6Label   = "llm-$OrgId-$Environment".ToLowerInvariant()
$pipV4Label   = "llm-$OrgId-$Environment-ipv4".ToLowerInvariant()
$regionLower  = $Region.ToLowerInvariant()
$ipv6Fqdn     = "$pipV6Label.$regionLower.cloudapp.azure.com"
$ipv4Fqdn     = "$pipV4Label.$regionLower.cloudapp.azure.com"

Write-Verbose "PIP names : IPv6=$pipV6Name, IPv4=$pipV4Name"
Write-Verbose "DNS labels: IPv6=$pipV6Label, IPv4=$pipV4Label"
Write-Verbose "FQDNs     : IPv6=$ipv6Fqdn, IPv4=$ipv4Fqdn"

# CAF tags.
$TagDictionary = [ordered]@{
    WorkloadName       = 'llm'
    ApplicationName    = 'llm-vllm'
    DataClassification = 'Non-business'
    Criticality        = 'Low'
    BusinessUnit       = 'IT'
    Env                = $Environment
}
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

function Ensure-PublicIp {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DnsLabel,
        [Parameter(Mandatory)][ValidateSet('IPv4','IPv6')][string]$Version
    )
    $existing = az network public-ip show --name $Name --resource-group $rgName 2>$null | ConvertFrom-Json
    if ($existing) {
        Write-Verbose "Public IP '$Name' already present, skipping."
        return
    }
    Write-Verbose "Creating public IP '$Name' ($Version, Standard SKU, Static, DNS '$DnsLabel')"
    az network public-ip create `
        --name $Name `
        --resource-group $rgName `
        --location $rg.location `
        --sku Standard `
        --allocation-method Static `
        --version $Version `
        --dns-name $DnsLabel `
        --tags $tags `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az network public-ip create '$Name' failed." }
}

Ensure-PublicIp -Name $pipV6Name -DnsLabel $pipV6Label -Version IPv6
Ensure-PublicIp -Name $pipV4Name -DnsLabel $pipV4Label -Version IPv4

# Emit FQDNs to verbose for the operator's records.
Write-Verbose "vLLM FQDNs (use IPv6 as the primary):"
Write-Verbose "  IPv6: https://$ipv6Fqdn"
Write-Verbose "  IPv4: https://$ipv4Fqdn"

Write-Verbose "Deploy LLM/vLLM public IPs complete."
