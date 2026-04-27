#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deallocate the LLM/vLLM VM (stop billing for compute).

.DESCRIPTION
  Runs `az vm deallocate` against `vmllmvllm001` in the workload RG.
  Idempotent: if the VM is already deallocated or missing, the script
  exits 0 with a friendly message rather than failing.

  Deallocation stops compute charges; the OS disk and the persistent
  data disk continue to incur (small) storage charges.

.NOTES
  This is a routine cost-control operation. Use `Start-LlmVm.ps1` to
  bring it back up. Both the IPv6 and IPv4 PIPs are static so the FQDNs
  do not change across stop/start cycles.

.EXAMPLE

  az login
  $VerbosePreference = 'Continue'
  ./c-workload/Stop-LlmVm.ps1
#>
[CmdletBinding()]
param (
    [string]$Purpose     = $ENV:DEPLOY_PURPOSE     ?? 'LLM',
    [string]$Workload    = $ENV:DEPLOY_WORKLOAD    ?? 'workload',
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    [string]$Instance    = $ENV:DEPLOY_INSTANCE    ?? '001'
)

$ErrorActionPreference = 'Stop'

$rgName = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$vmName = "vm$Purpose" + 'vllm' + $Instance
$vmName = $vmName.ToLowerInvariant()

$vm = az vm show --name $vmName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $vm) {
    Write-Verbose "VM '$vmName' not found in '$rgName'; nothing to stop."
    exit 0
}

# Inspect power state. Idempotency: only call deallocate if not already deallocated.
$instance = az vm get-instance-view --name $vmName --resource-group $rgName 2>$null | ConvertFrom-Json
$powerState = ($instance.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).code
Write-Verbose "Current power state: $powerState"
if ($powerState -eq 'PowerState/deallocated') {
    Write-Verbose "VM '$vmName' is already deallocated; nothing to do."
    exit 0
}

Write-Verbose "Deallocating VM '$vmName' ..."
az vm deallocate --name $vmName --resource-group $rgName --output none
if ($LASTEXITCODE -ne 0) { throw "az vm deallocate '$vmName' failed." }
Write-Verbose "VM '$vmName' deallocated."
