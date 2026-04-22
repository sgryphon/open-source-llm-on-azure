#!/usr/bin/env pwsh

<# .SYNOPSIS
  Remove the Azure development infrastructure resource group.
#>
[CmdletBinding()]
param (
    ## Purpose prefix
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Workload prefix
    [string]$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## Instance number uniquifier
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
)

$ErrorActionPreference="Stop"

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Removing from subscription ID $SubscriptionId"

# Assumes all the same single instance

$coreRgName = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$workloadRgName = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()

# Remove in reverse order

az group delete --name $workloadRgName
az group delete --name $coreRgName
