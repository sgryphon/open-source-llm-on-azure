#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy Azure Monitor and App Insights into core shared resource group.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * Log Analytics Workspace `log-llm-shared-dev-001`
    * App Insights `appi-llm-shared-dev-001`
    * Virtual network `vnet-llm-hub-australiaeast-001`, dual-stack (IPv6 ULA + IPv4)

.NOTES
  This creates Azure Monitor in the shared core resource group.

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
   ./01-Deploy-AzureMonitor.ps1
#>
[CmdletBinding()]
param (
    ## Purpose prefix
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## Instance number uniquifier
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
#>

$ErrorActionPreference="Stop"

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying shared Azure Monitor in subscription '$SubscriptionId'"

# Following standard naming conventions from Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming
# With an additional organisation or subscription identifier (after app name) in global names to make them unique 

$rgName = "rg-$Purpose-core-$Instance".ToLowerInvariant()

# Landing zone templates have Azure Monitor (we also add app insights)

$logName = "log-$Purpose-shared-$Environment".ToLowerInvariant()
$appiName = "appi-$Purpose-shared-$Environment".ToLowerInvariant()

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

# Copy location details from the RG
$rg = az group show --name $rgName | ConvertFrom-Json

# Create

Write-Verbose "Creating log analytics workspace $logName"

az monitor log-analytics workspace create `
  --resource-group $rgName `
  -l $rg.location `
  --workspace-name $logName `
  --tags $tags

Write-Verbose "Creating app insights (may take a while) $appiName"
az extension add -n application-insights

$ai = az monitor app-insights component create `
  --app $appiName `
  -g $rgName `
  --location $rg.location `
  --workspace $logName `
  --tags $tags | ConvertFrom-Json

# copy the key into another variable, to ensure the property is dereferenced when passing to
# the az command line
$aiKey = $ai.instrumentationKey
$aiConnectionString = $ai.connectionString

Write-Verbose "Client App Instrumentation Key: $aiKey"
Write-Verbose "Client App Connection String: $aiConnectionString"
Write-Verbose "Deploy Azure Monitor $logName complete"
