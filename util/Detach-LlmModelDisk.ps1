#!/usr/bin/env pwsh

<# .SYNOPSIS
  Detach the persistent model data disk from the LLM VM, optionally
  deleting the VM, while leaving the data disk intact in the workload RG.

.DESCRIPTION
  Two phases, both idempotent:

    1. Deallocate the VM (`az vm deallocate`). Tolerated as a no-op if
       the VM is already deallocated or missing.
    2. Detach the data disk (`az vm disk detach`). Tolerated as a no-op
       if the disk is already detached or the VM is missing.

  With `-DeleteVm`:

    3. Delete the VM (`az vm delete --yes`). The OS disk and the NIC are
       cleaned up implicitly by `az vm delete` (Azure default).

  THIS SCRIPT NEVER DELETES THE DATA DISK. Regardless of flags, the
  Managed Disk `disk-llm-vllm-models-<env>-001` remains in the workload
  RG, ready for a future `06-Deploy-LlmVm.ps1` to re-attach.

  USE CASES
    - "Rebuild the VM and keep the model": run with `-DeleteVm`, then
      re-run `c-workload/06-Deploy-LlmVm.ps1`. The same disk is attached;
      cloud-init does NOT reformat (the `blkid` guard sees the existing
      ext4 filesystem); `vllm.service` starts automatically because
      `ConditionPathExists` is satisfied immediately after the cert
      issuance step finishes.
    - "Park the model": run without `-DeleteVm` to detach without
      destroying the VM (rare; usually you just `Stop-LlmVm.ps1`).

.NOTES
  The data disk's lifecycle is owned by `c-workload/05-Deploy-LlmDataDisk.ps1`.
  To delete the data disk explicitly, use `az disk delete` against
  `disk-llm-vllm-models-<env>-001` directly.

.EXAMPLE

  az login
  $VerbosePreference = 'Continue'
  ./util/Detach-LlmModelDisk.ps1 -DeleteVm
#>
[CmdletBinding()]
param (
    ## Also delete the VM (and its OS disk and NIC) after detaching the data disk.
    [switch]$DeleteVm = ($ENV:DEPLOY_DELETE_VM -eq 'true' -or $ENV:DEPLOY_DELETE_VM -eq '1'),
    [string]$Purpose     = $ENV:DEPLOY_PURPOSE     ?? 'LLM',
    [string]$Workload    = $ENV:DEPLOY_WORKLOAD    ?? 'workload',
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    [string]$Instance    = $ENV:DEPLOY_INSTANCE    ?? '001'
)

$ErrorActionPreference = 'Stop'

$rgName   = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$vmName   = ("vm$Purpose" + 'vllm' + $Instance).ToLowerInvariant()
$diskName = "disk-$Purpose-vllm-models-$Environment-$Instance".ToLowerInvariant()

# Guard: never, ever delete the data disk.
$disk = az disk show --name $diskName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $disk) {
    Write-Warning "Data disk '$diskName' not found in '$rgName'. Nothing to detach (and nothing to protect)."
}

$vm = az vm show --name $vmName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $vm) {
    Write-Verbose "VM '$vmName' not found in '$rgName'."
    if ($disk -and $disk.diskState -eq 'Unattached') {
        Write-Verbose "Data disk '$diskName' is already Unattached. Nothing to do."
        Write-Verbose "Detach LLM/vLLM model disk complete (no-op)."
        return
    }
    if ($DeleteVm) {
        Write-Verbose "VM is already gone; -DeleteVm is moot."
    }
    return
}

# 1. Deallocate. Idempotent.
$instance = az vm get-instance-view --name $vmName --resource-group $rgName 2>$null | ConvertFrom-Json
$powerState = ($instance.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).code
if ($powerState -ne 'PowerState/deallocated') {
    Write-Verbose "Deallocating VM '$vmName' (current state: $powerState) ..."
    az vm deallocate --name $vmName --resource-group $rgName --output none
    if ($LASTEXITCODE -ne 0) { throw "az vm deallocate '$vmName' failed." }
} else {
    Write-Verbose "VM '$vmName' already deallocated; skipping."
}

# 2. Detach the data disk if it's attached to this VM. Idempotent.
$attached = $false
if ($disk -and $disk.managedBy) {
    $expectedSuffix = "/virtualMachines/$vmName"
    if ($disk.managedBy.ToLowerInvariant().EndsWith($expectedSuffix.ToLowerInvariant())) {
        $attached = $true
    } else {
        Write-Warning "Data disk '$diskName' is attached to '$($disk.managedBy)', not to '$vmName'. Refusing to touch it."
    }
}
if ($attached) {
    Write-Verbose "Detaching data disk '$diskName' from VM '$vmName' ..."
    az vm disk detach --vm-name $vmName --resource-group $rgName --name $diskName --output none
    if ($LASTEXITCODE -ne 0) { throw "az vm disk detach '$diskName' failed." }
} else {
    Write-Verbose "Data disk '$diskName' is not attached to '$vmName'; nothing to detach."
}

# 3. Optionally delete the VM. NEVER touches the data disk.
if ($DeleteVm) {
    Write-Verbose "Deleting VM '$vmName' (data disk '$diskName' will remain in '$rgName') ..."
    az vm delete --name $vmName --resource-group $rgName --yes --output none
    if ($LASTEXITCODE -ne 0) { throw "az vm delete '$vmName' failed." }
    Write-Verbose "VM '$vmName' deleted. Data disk '$diskName' is preserved."
} else {
    Write-Verbose "VM '$vmName' kept (pass -DeleteVm to also delete the VM)."
}

# Final invariant check.
$diskAfter = az disk show --name $diskName --resource-group $rgName 2>$null | ConvertFrom-Json
if ($diskAfter) {
    Write-Verbose "Data disk '$diskName' state after detach: $($diskAfter.diskState)"
} else {
    throw "INVARIANT VIOLATION: data disk '$diskName' no longer exists. This script must never delete the data disk; investigate immediately."
}

Write-Verbose "Detach LLM/vLLM model disk complete."
