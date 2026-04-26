#!/usr/bin/env pwsh

<# .SYNOPSIS
  Rotate the vLLM API key without rebuilding the VM.

.DESCRIPTION
  Three steps:

    1. Set a new version of the `vllm-api-key` secret in the shared
       Key Vault (256-bit URL-safe-base64 random value).
    2. Run an inline script on the VM via `az vm run-command invoke`
       that re-fetches the secret with the UAMI and rewrites
       `/etc/vllm/vllm.env` (mode 0600, owner `vllm:vllm`).
    3. `systemctl restart vllm` so the new key takes effect.

  After this script returns successfully, the OLD key is rejected and
  the NEW key is accepted. No VM rebuild, no certificate work, no
  restart of cloud-init.

  Operator UX: this script PRINTS the new key to the operator's
  terminal once at the end. Capture it (e.g. into a password manager
  and into the OpenCode config) before clearing the screen. The same
  value remains retrievable from Key Vault for as long as the secret
  version is current.

.NOTES
  The VM must be running. If the VM is deallocated, start it first with
  `Start-LlmVm.ps1`.

.EXAMPLE

  az login
  $VerbosePreference = 'Continue'
  ./c-workload/Rotate-LlmApiKey.ps1
#>
[CmdletBinding()]
param (
    [string]$Purpose     = $ENV:DEPLOY_PURPOSE     ?? 'LLM',
    [string]$Workload    = $ENV:DEPLOY_WORKLOAD    ?? 'workload',
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    [string]$OrgId       = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
    [string]$Instance    = $ENV:DEPLOY_INSTANCE    ?? '001'
)

$ErrorActionPreference = 'Stop'

$rgName     = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$kvName     = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()
$vmName     = ("vm$Purpose" + 'vllm' + $Instance).ToLowerInvariant()
$apiKeySecretName = 'vllm-api-key'
$envFile    = '/etc/vllm/vllm.env'

# 1. Verify VM is reachable; running-state required for run-command.
$instance = az vm get-instance-view --name $vmName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $instance) { throw "VM '$vmName' not found in '$rgName'." }
$powerState = ($instance.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).code
if ($powerState -ne 'PowerState/running') {
    throw "VM '$vmName' is in state '$powerState'. Run Start-LlmVm.ps1 first."
}

# 2. Generate a 256-bit URL-safe-base64 random key.
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$newKey = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
Write-Verbose "Generated new $($newKey.Length)-char API key."

# 3. Set new secret version in Key Vault.
Write-Verbose "Writing new version of '$apiKeySecretName' to Key Vault '$kvName' ..."
az keyvault secret set --vault-name $kvName --name $apiKeySecretName --value $newKey --output none
if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set '$apiKeySecretName' failed." }

# 4. On the VM: re-fetch the secret with the UAMI and rewrite vllm.env.
# The UAMI is already logged in (cloud-init does `az login --identity`
# once at first boot and the token cache persists). If the cache has
# expired, the inline script logs in again.
$inline = @'
set -euo pipefail
KV_NAME="__KV__"
SECRET_NAME="__SECRET__"
ENV_FILE="__ENVFILE__"
UAMI_CLIENT_ID=$(grep -E '^UAMI_CLIENT_ID=' /usr/local/sbin/vllm-bootstrap.sh 2>/dev/null | head -1 | cut -d"'" -f2 || true)
if [ -z "$UAMI_CLIENT_ID" ]; then
    # Fallback: re-read from instance metadata (any UAMI on the VM works).
    UAMI_CLIENT_ID=$(curl -fsS -H Metadata:true \
        "http://169.254.169.254/metadata/identity/info?api-version=2018-02-01" \
        | python3 -c 'import json,sys; print(list(json.load(sys.stdin).get("identityIds",[""]))[0] or "")')
fi
# Login may already be cached; ignore failure here, fall through to the fetch.
az login --identity --client-id "$UAMI_CLIENT_ID" --allow-no-subscriptions --output none 2>/dev/null || true
NEW_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name "$SECRET_NAME" --query value -o tsv)
if [ -z "$NEW_KEY" ]; then
    echo "ERROR: failed to fetch '$SECRET_NAME' from '$KV_NAME'" >&2
    exit 1
fi
# Preserve any non-VLLM_API_KEY lines (e.g. HF_HOME) in the env file.
TMPFILE=$(mktemp)
if [ -f "$ENV_FILE" ]; then
    grep -v '^VLLM_API_KEY=' "$ENV_FILE" > "$TMPFILE" || true
fi
printf 'VLLM_API_KEY=%s\n' "$NEW_KEY" >> "$TMPFILE"
install -m 0600 -o vllm -g vllm "$TMPFILE" "$ENV_FILE"
rm -f "$TMPFILE"
systemctl restart vllm
systemctl is-active --quiet vllm \
    || (journalctl -u vllm --since "2 min ago" -n 100; exit 1)
echo "ROTATE_OK"
'@
$inline = $inline.Replace('__KV__', $kvName).Replace('__SECRET__', $apiKeySecretName).Replace('__ENVFILE__', $envFile)

Write-Verbose "Rewriting $envFile on '$vmName' and restarting vllm.service ..."
$rcRaw = az vm run-command invoke `
    --resource-group $rgName `
    --name $vmName `
    --command-id RunShellScript `
    --scripts $inline `
    --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "run-command invoke failed; output follows:"
    Write-Warning $rcRaw
    throw "Failed to apply new API key on '$vmName'."
}
$rcParsed = $rcRaw | ConvertFrom-Json -ErrorAction SilentlyContinue
$rcStdout = ($rcParsed.value | ForEach-Object { $_.message }) -join "`n"
if ($rcStdout -notmatch 'ROTATE_OK') {
    Write-Warning $rcStdout
    throw "Rotate did not complete successfully on '$vmName'."
}

Write-Verbose "API key rotated; vllm.service is active with the new key."
Write-Host ""
Write-Host "=== NEW vLLM API KEY (capture into your OpenCode config now) ==="
Write-Host $newKey
Write-Host "================================================================"
