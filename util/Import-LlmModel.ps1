#!/usr/bin/env pwsh

<# .SYNOPSIS
  Download the vLLM model from Hugging Face onto the persistent data disk
  attached to the LLM VM, via `az vm run-command invoke`. Then start
  vllm.service.

.DESCRIPTION
  This is the operator-triggered model-load step. It runs an inline
  shell script ON THE VM that:

    1. Short-circuits if `<mount>/<dir>/config.json` already exists.
       The data disk persists across VM rebuilds; if the model is
       already there, this script is a no-op.
    2. Installs `huggingface-hub` into the existing vLLM venv.
    3. Runs `huggingface-cli download <repo> --local-dir <mount>/<dir>
       --local-dir-use-symlinks False` to materialise the model files
       (tokenizer, config, AWQ-quantised weights, ~5.5 GiB).
    4. Chowns the mount tree to `vllm:vllm`.
    5. `systemctl start vllm`. The unit's `ConditionPathExists` is now
       satisfied so the start succeeds.
    6. Verifies `systemctl is-active --quiet vllm`. On failure, dumps
       the recent journal lines for the unit and exits non-zero.

  The operator's workstation never holds the model bytes -- the VM
  fetches directly from Hugging Face using its own outbound internet
  (which is already needed for `apt`, `pip`, ACME, NVIDIA repos).

  IDEMPOTENCY
  Re-running this script after a successful download is a no-op: the
  short-circuit on `config.json` short-cuts the HF call, the chown is
  idempotent, and `systemctl start` of an already-active unit is a no-op.

.NOTES
  Default model is Qwen2.5-Coder-7B-Instruct AWQ-INT4, which fits in T4
  16 GiB VRAM with headroom for a 32k-token context. Override with
  `-ModelRepoId` and `-ModelDirName` if you swap models.

  The first run can take 5+ minutes depending on HF bandwidth. The
  script streams the run-command output as Azure CLI returns it.

.EXAMPLE

  az login
  $VerbosePreference = 'Continue'
  ./util/Download-LlmModelToDisk.ps1
#>
[CmdletBinding()]
param (
    ## Hugging Face model repo id.
    [string]$ModelRepoId = $ENV:DEPLOY_MODEL_REPO_ID ?? 'Qwen/Qwen2.5-Coder-7B-Instruct-AWQ',
    ## Subdirectory under the data-disk mount where the model files live.
    [string]$ModelDirName = $ENV:DEPLOY_MODEL_DIR_NAME ?? 'qwen2.5-coder-7b-awq',
    ## Mount point of the model data disk on the VM.
    [string]$ModelMountPoint = $ENV:DEPLOY_MODEL_MOUNT_POINT ?? '/opt/models',
    [string]$Purpose     = $ENV:DEPLOY_PURPOSE     ?? 'LLM',
    [string]$Workload    = $ENV:DEPLOY_WORKLOAD    ?? 'workload',
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    [string]$Region      = $ENV:DEPLOY_REGION      ?? 'australiaeast',
    [string]$Instance    = $ENV:DEPLOY_INSTANCE    ?? '001'
)

$ErrorActionPreference = 'Stop'

$rgName = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$vmName = ("vm$Purpose" + 'vllm' + $Instance).ToLowerInvariant()

$vm = az vm show --name $vmName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $vm) { throw "VM '$vmName' not found in '$rgName'." }

# VM must be running for run-command to dispatch.
$instance = az vm get-instance-view --name $vmName --resource-group $rgName 2>$null | ConvertFrom-Json
$powerState = ($instance.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).code
if ($powerState -ne 'PowerState/running') {
    throw "VM '$vmName' is in state '$powerState'. Run c-workload/Start-LlmVm.ps1 first."
}

Write-Verbose "Will download '$ModelRepoId' into '$ModelMountPoint/$ModelDirName' on '$vmName'."

# Inline script. Token substitution via .Replace() (no PS string interp into
# the heredoc, to keep the bash semantics readable).
$inline = @'
set -euo pipefail
REPO_ID="__REPO__"
TARGET="__MOUNT__/__DIR__"
VENV=/opt/vllm/.venv

if [ -f "$TARGET/config.json" ]; then
    echo "MODEL_ALREADY_PRESENT: $TARGET/config.json exists; nothing to download."
    # Still ensure the service is running (e.g. after a stop/start cycle).
    systemctl start vllm 2>/dev/null || true
    if systemctl is-active --quiet vllm; then
        echo "DOWNLOAD_OK"
        exit 0
    fi
    echo "WARN: vllm.service is not active even though the model is present. Recent logs:"
    journalctl -u vllm --since "2 min ago" -n 100 || true
    exit 1
fi

mkdir -p "$TARGET"
chown vllm:vllm "$TARGET"

# Install hf hub in the existing vLLM venv. -q to keep run-command output small.
"$VENV/bin/pip" install -q huggingface-hub

# Download the model. --local-dir-use-symlinks False writes real files into
# $TARGET (not symlinks into ~/.cache/huggingface) so a future VM rebuild
# that re-attaches the disk sees the files directly.
sudo -u vllm "$VENV/bin/huggingface-cli" download \
    "$REPO_ID" \
    --local-dir "$TARGET" \
    --local-dir-use-symlinks False

chown -R vllm:vllm __MOUNT__

systemctl start vllm
if ! systemctl is-active --quiet vllm; then
    echo "ERROR: vllm.service failed to start. Recent logs:"
    journalctl -u vllm --since "2 min ago" -n 200 || true
    exit 1
fi

echo "DOWNLOAD_OK"
'@
$inline = $inline.Replace('__REPO__',  $ModelRepoId).
                  Replace('__MOUNT__', $ModelMountPoint).
                  Replace('__DIR__',   $ModelDirName)

Write-Verbose "Dispatching model download via run-command (this can take ~5+ min on first run)..."
$rcRaw = az vm run-command invoke `
    --resource-group $rgName `
    --name $vmName `
    --command-id RunShellScript `
    --scripts $inline `
    --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "run-command invoke failed; output follows:"
    Write-Warning $rcRaw
    throw "Model download failed on '$vmName'."
}
$rcParsed = $rcRaw | ConvertFrom-Json -ErrorAction SilentlyContinue
$rcStdout = ($rcParsed.value | ForEach-Object { $_.message }) -join "`n"
Write-Host $rcStdout
if ($rcStdout -notmatch 'DOWNLOAD_OK') {
    throw "Model download did not complete successfully on '$vmName' (sentinel 'DOWNLOAD_OK' not found)."
}

Write-Verbose ""
Write-Verbose "Model is on disk and vllm.service is active."
