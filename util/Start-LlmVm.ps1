#!/usr/bin/env pwsh

<# .SYNOPSIS
  Start the LLM/vLLM VM after a deallocate.

.DESCRIPTION
  Runs `az vm start` against `vmllmvllm001` in the workload RG.
  Idempotent: if the VM is already running or missing, the script exits
  0 with a friendly message rather than failing.

  The persistent data disk re-attaches automatically; cloud-init does
  not run again (it is gated by waagent's first-boot marker), but the
  fstab entry written on first boot mounts the data disk via
  `LABEL=llm-models`. `vllm.service` starts automatically once the
  model files are present (its `ConditionPathExists` is satisfied).

.EXAMPLE

  az login
  $VerbosePreference = 'Continue'
  ./c-workload/Start-LlmVm.ps1
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
    Write-Verbose "VM '$vmName' not found in '$rgName'; nothing to start."
    exit 0
}

$instance = az vm get-instance-view --name $vmName --resource-group $rgName 2>$null | ConvertFrom-Json
$powerState = ($instance.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).code
Write-Verbose "Current power state: $powerState"
if ($powerState -eq 'PowerState/running') {
    Write-Verbose "VM '$vmName' is already running; nothing to do."
    exit 0
}

Write-Verbose "Starting VM '$vmName' ..."
az vm start --name $vmName --resource-group $rgName --output none
if ($LASTEXITCODE -ne 0) { throw "az vm start '$vmName' failed." }
Write-Verbose "VM '$vmName' started."
