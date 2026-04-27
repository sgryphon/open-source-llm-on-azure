#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy the GPU VM that runs vLLM, with cloud-init bootstrap and the
  persistent model data disk attached.

.DESCRIPTION
  Creates, idempotently via Azure CLI, into the workload resource group:

    * One NIC `nic-01-vmllmvllm001-<env>-001` on the LLM subnet, with:
        - a primary IPv4 ip-config attached to the IPv4 PIP, and
        - a secondary IPv6 ip-config `ipc-01-vmllmvllm001-<env>-001`
          attached to the IPv6 PIP.
      The IPv6 FQDN is the *cert primary* and the FQDN OpenCode connects
      to; the IPv4 ip-config exists because Azure does not support
      single-stack IPv6 NICs.
    * One Ubuntu 22.04 LTS GPU VM `vmllmvllm001` of size
      `Standard_NC4as_T4_v3` (NVIDIA T4), bound to the workload UAMI
      `id-llm-vllm-<env>-001`, with the rendered cloud-init from
      `data/vllm-cloud-init.txt` as `--custom-data`, and the persistent
      data disk `disk-llm-vllm-models-<env>-001` attached at LUN 0 via
      `--attach-data-disks` (NEVER `--data-disk-sizes-gb`).
    * NVIDIA GPU Driver Linux extension on the VM (idempotent).
    * Optional auto-shutdown schedule (`-ShutdownUtc`, default `0900`).
    * A `cloud-init status --wait` poll via `az vm run-command invoke`
      that streams `/var/log/cloud-init-output.log` to the operator on
      failure.

  No secrets are substituted into cloud-init: the API key is fetched at
  first boot by cloud-init from Key Vault using the UAMI. The model
  bytes are NOT downloaded by cloud-init either; on success the
  `vllm.service` unit is `enabled` but `inactive` (its
  `ConditionPathExists` keeps it that way until
  `util/Download-LlmModelToDisk.ps1` populates the data disk).

.NOTES
  IPv6 FQDN = "llm-<OrgId>-<Environment>.<Location>.cloudapp.azure.com"
  IPv4 FQDN = "llm-<OrgId>-<Environment>-ipv4.<Location>.cloudapp.azure.com"

  PRECHECKS
  Before any create operation, the script:
    1. Resolves the T4 quota (`standardNCASv3Family`) in the region and
       aborts with a clear message if zero. Quota is the most common
       blocker on a fresh subscription.
    2. Resolves the data disk and asserts it is `Unattached` or already
       attached to `vmllmvllm001`. If attached elsewhere, abort: this
       almost always means a previous detach didn't complete, and silent
       re-attach would surprise the operator.

  DATA DISK LIFECYCLE
  The data disk is created standalone by `05-Deploy-LlmDataDisk.ps1`; this
  script never resizes, retypes, or recreates it. Rebuilding the VM
  (delete + re-run this script) re-uses the same disk and its existing
  ext4 filesystem (cloud-init's `mkfs` step is gated by `blkid`).

  CONVENTIONS
  Follows the Azure CAF naming and tagging conventions.

.EXAMPLE

  az login
  az account set --subscription <subscription id>
  $VerbosePreference = 'Continue'
  $env:DEPLOY_ACME_EMAIL = 'ops@example.com'
  ./c-workload/06-Deploy-LlmVm.ps1
#>
[CmdletBinding()]
param (
    ## Email address registered with Let's Encrypt (REQUIRED).
    [string]$AcmeEmail = $ENV:DEPLOY_ACME_EMAIL,
    ## Use the Let's Encrypt staging environment instead of production.
    [switch]$AcmeStaging = ($ENV:DEPLOY_ACME_STAGING -eq 'true' -or $ENV:DEPLOY_ACME_STAGING -eq '1'),
    ## Pinned vLLM version. Change deliberately; vLLM CLI flags drift between minors.
    [string]$VllmVersion = $ENV:DEPLOY_VLLM_VERSION ?? '0.6.4',
    ## Served model name (the `id` returned by `/v1/models` and used in chat requests).
    [string]$ServedModelName = $ENV:DEPLOY_SERVED_MODEL_NAME ?? 'qwen2.5-coder-7b',
    ## Subdirectory under the model mount where the model files live.
    [string]$ModelDirName = $ENV:DEPLOY_MODEL_DIR_NAME ?? 'qwen2.5-coder-7b-awq',
    ## Mount point for the data disk on the VM.
    [string]$ModelMountPoint = $ENV:DEPLOY_MODEL_MOUNT_POINT ?? '/opt/models',
    ## Auto-shutdown time in UTC (HHMM). Empty string disables.
    [string]$ShutdownUtc = $ENV:DEPLOY_SHUTDOWN_UTC ?? '0900',
    ## Email to send auto-shutdown notification to (optional).
    [string]$ShutdownEmail = $ENV:DEPLOY_SHUTDOWN_EMAIL ?? '',
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
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001',
    ## VM size. Default is the cheapest T4 SKU.
    [string]$VmSize = $ENV:DEPLOY_VM_SIZE ?? 'Standard_NC4as_T4_v3',
    ## Linux admin account name (authentication via SSH key).
    [string]$AdminUsername = $ENV:DEPLOY_ADMIN_USERNAME ?? 'azureuser'
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$AcmeEmail = $ENV:DEPLOY_ACME_EMAIL
$AcmeStaging = $false
$VllmVersion = '0.6.4'
$ServedModelName = 'qwen2.5-coder-7b'
$ModelDirName = 'qwen2.5-coder-7b-awq'
$ModelMountPoint = '/opt/models'
$ShutdownUtc = '0900'
$ShutdownEmail = ''
$Purpose = 'LLM'
$Workload = 'workload'
$Environment = 'Dev'
$Region = 'australiaeast'
$OrgId = "0x$((az account show --query id --output tsv).Substring(0,4))"
$Instance = '001'
$VmSize = 'Standard_NC4as_T4_v3'
$AdminUsername = 'azureuser'
#>

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($AcmeEmail)) {
    throw 'You must supply a value for -AcmeEmail or set environment variable DEPLOY_ACME_EMAIL.'
}

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying LLM/vLLM VM for environment '$Environment' in subscription '$SubscriptionId'"

# ---------------------------------------------------------------------------
# Resolve dependencies (RG, VNet, subnet, NSG, PIPs, UAMI, Key Vault, disk).
# ---------------------------------------------------------------------------

$rgName     = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$rg         = az group show --name $rgName 2>$null | ConvertFrom-Json
if (-not $rg) {
    throw "Workload resource group '$rgName' not found. Run a-infrastructure/02-Initialize-WorkloadRg.ps1 first."
}
$location      = $rg.location
$locationLower = $location.ToLowerInvariant()
if ($locationLower -ne $Region.ToLowerInvariant()) {
    Write-Warning "Workload RG location '$location' does not match -Region '$Region'; using RG location."
}

$vnetName    = "vnet-$Purpose-$Workload-$Environment-$locationLower-$Instance".ToLowerInvariant()
$subnetName  = "snet-$Purpose-vllm-$Environment-$locationLower-$Instance".ToLowerInvariant()
$nsgName     = "nsg-$Purpose-vllm-$Environment-$Instance".ToLowerInvariant()

$vnet = az network vnet show --name $vnetName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $vnet) { throw "VNet '$vnetName' not found. Run a-infrastructure/02-Initialize-WorkloadRg.ps1 first." }

$snet = az network vnet subnet show --name $subnetName -g $rgName --vnet-name $vnetName 2>$null | ConvertFrom-Json
if (-not $snet) { throw "Subnet '$subnetName' not found. Run c-workload/01-Deploy-LlmSubnet.ps1 first." }

$nsg = az network nsg show --name $nsgName -g $rgName 2>$null | ConvertFrom-Json
if (-not $nsg) { throw "NSG '$nsgName' not found. Run c-workload/01-Deploy-LlmSubnet.ps1 first." }

$pipV6Name  = "pip-$Purpose-vllm-$Environment-$locationLower-$Instance".ToLowerInvariant()
$pipV4Name  = "pipv4-$Purpose-vllm-$Environment-$locationLower-$Instance".ToLowerInvariant()
$pipV6      = az network public-ip show --name $pipV6Name --resource-group $rgName 2>$null | ConvertFrom-Json
$pipV4      = az network public-ip show --name $pipV4Name --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $pipV6) { throw "Public IP '$pipV6Name' not found. Run c-workload/04-Deploy-LlmPublicIp.ps1 first." }
if (-not $pipV4) { throw "Public IP '$pipV4Name' not found. Run c-workload/04-Deploy-LlmPublicIp.ps1 first." }
$ipv6Fqdn = $pipV6.dnsSettings.fqdn
$ipv4Fqdn = $pipV4.dnsSettings.fqdn
if (-not $ipv6Fqdn -or -not $ipv4Fqdn) { throw "PIPs are missing DNS FQDNs; cert issuance will fail." }

$identityName = "id-$Purpose-vllm-$Environment-$Instance".ToLowerInvariant()
$identity     = az identity show --name $identityName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $identity) { throw "Managed identity '$identityName' not found. Run c-workload/03-Deploy-LlmIdentity.ps1 first." }
$uamiResourceId = $identity.id
$uamiClientId   = $identity.clientId

# Shared Key Vault (in the core RG).
$coreRgName = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$kvName     = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()
$kv         = az keyvault show --name $kvName 2>$null | ConvertFrom-Json
if (-not $kv) { throw "Key Vault '$kvName' not found. Run b-shared/02-Deploy-KeyVault.ps1 first." }

$apiKeySecretName = 'vllm-api-key'
$apiKeySecret     = az keyvault secret show --vault-name $kvName --name $apiKeySecretName 2>$null | ConvertFrom-Json
if (-not ($apiKeySecret -and $apiKeySecret.id)) {
    throw "Key Vault secret '$apiKeySecretName' is missing in '$kvName'. Run c-workload/02-Deploy-LlmKeyVaultSecret.ps1 first."
}

$diskName = "disk-$Purpose-vllm-models-$Environment-$Instance".ToLowerInvariant()
$disk     = az disk show --name $diskName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $disk) {
    throw "Data disk '$diskName' not found. Run c-workload/05-Deploy-LlmDataDisk.ps1 first."
}
$diskId = $disk.id

# ---------------------------------------------------------------------------
# Derived names.
# ---------------------------------------------------------------------------

$appName    = 'vllm'
$vmName     = "vm$Purpose$appName$Instance".ToLowerInvariant()    # e.g. vmllmvllm001
$vmOsDisk   = "osdisk$vmName".ToLowerInvariant()
$nicName    = "nic-01-$vmName-$Environment-$Instance".ToLowerInvariant()
$ipcV6Name  = "ipc-01-$vmName-$Environment-$Instance".ToLowerInvariant()

Write-Verbose "Resolved : RG=$rgName, VNet=$vnetName, Subnet=$subnetName, NSG=$nsgName"
Write-Verbose "         : KV=$kvName, UAMI=$identityName, Disk=$diskName"
Write-Verbose "         : VM=$vmName, NIC=$nicName, IPv6 FQDN=$ipv6Fqdn, IPv4 FQDN=$ipv4Fqdn"

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

# ---------------------------------------------------------------------------
# Pre-checks: T4 quota, data-disk attach state.
# ---------------------------------------------------------------------------

# Quota: standardNCASv3Family covers Standard_NC4as_T4_v3 / NC8as_T4_v3 / NC16as_T4_v3 / NC64as_T4_v3.
Write-Verbose "Checking GPU quota for 'standardNCASv3Family' in '$location'..."
$quota = az vm list-usage --location $location --query "[?name.value=='standardNCASv3Family'] | [0]" --output json 2>$null | ConvertFrom-Json
if ($quota) {
    Write-Verbose "  current usage: $($quota.currentValue) / limit: $($quota.limit)"
    if ([int]$quota.limit -lt 4) {
        throw @"
GPU quota 'standardNCASv3Family' in '$location' is $($quota.limit). Standard_NC4as_T4_v3 needs 4 vCPUs.
Request a quota increase: https://learn.microsoft.com/azure/quotas/per-vm-quota-requests
"@
    }
} else {
    Write-Warning "Could not read 'standardNCASv3Family' quota for '$location' (the quota family may not be exposed in this region). Proceeding; VM create will fail clearly if quota is genuinely zero."
}

# Disk attach state: Unattached, or attached to *this* VM. Anything else aborts.
$diskState = $disk.diskState
Write-Verbose "Data disk '$diskName' state: $diskState"
if ($diskState -eq 'Attached' -or $diskState -eq 'Reserved') {
    $managedBy = $disk.managedBy
    if ($managedBy) {
        $expectedSuffix = "/virtualMachines/$vmName"
        if (-not $managedBy.ToLowerInvariant().EndsWith($expectedSuffix.ToLowerInvariant())) {
            throw @"
Data disk '$diskName' is attached to '$managedBy', not to '$vmName'. Refusing to silently re-attach.
Detach manually with util/Detach-LlmModelDisk.ps1 (or 'az vm disk detach') and re-run this script.
"@
        }
        Write-Verbose "  data disk already attached to '$vmName' (re-run path)."
    }
}

# ---------------------------------------------------------------------------
# Render cloud-init (substitute #INIT_*# tokens, write to ./temp/...~).
# ---------------------------------------------------------------------------

$tempDir = Join-Path $PSScriptRoot 'temp'
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$tempDir = (Resolve-Path $tempDir).ProviderPath
$templatePath = Join-Path $PSScriptRoot 'data' 'vllm-cloud-init.txt'
$renderedPath = Join-Path $tempDir     'vllm-cloud-init.txt~'
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Cloud-init template not found at '$templatePath'."
}

$acmeStagingFlag = if ($AcmeStaging) { '--test-cert' } else { '' }
if ($AcmeStaging) {
    Write-Warning "ACME staging mode: cert will not be trusted by browsers/OpenCode without -SkipCertificateCheck."
}

Write-Verbose "Rendering cloud-init from '$templatePath' -> '$renderedPath'"
# Use literal .Replace() (not PS -replace) so any regex metacharacters in
# substituted values pass through unchanged.
$rendered = (Get-Content -Path $templatePath -Raw)
$subs = [ordered]@{
    '#INIT_HOST_NAME#'           = $ipv6Fqdn
    '#INIT_HOST_NAME_IPV4#'      = $ipv4Fqdn
    '#INIT_KEY_VAULT_NAME#'      = $kvName
    '#INIT_API_KEY_SECRET_NAME#' = $apiKeySecretName
    '#INIT_UAMI_CLIENT_ID#'      = $uamiClientId
    '#INIT_CERT_EMAIL#'          = $AcmeEmail
    '#INIT_ACME_STAGING_FLAG#'   = $acmeStagingFlag
    '#INIT_VLLM_VERSION#'        = $VllmVersion
    '#INIT_SERVED_MODEL_NAME#'   = $ServedModelName
    '#INIT_MODEL_DIR_NAME#'      = $ModelDirName
    '#INIT_MODEL_MOUNT_POINT#'   = $ModelMountPoint
}
foreach ($k in $subs.Keys) {
    $rendered = $rendered.Replace($k, [string]$subs[$k])
}
Set-Content -Path $renderedPath -Value $rendered -NoNewline

# Post-render assertions.
$leftover = [regex]::Matches($rendered, '#INIT_[A-Z_]+#')
if ($leftover.Count -gt 0) {
    throw "Unsubstituted cloud-init tokens remain: $(($leftover | ForEach-Object { $_.Value }) -join ', ')"
}
# Defensive: API key value must NEVER appear in the substituted file. We
# never put it in $subs, but assert explicitly so a future careless edit
# fails loudly.
$apiKeyValueProbe = (az keyvault secret show --vault-name $kvName --name $apiKeySecretName --query value -o tsv 2>$null)
if ($apiKeyValueProbe -and $rendered.Contains($apiKeyValueProbe)) {
    throw "Rendered cloud-init contains the API key secret value. Aborting before writing to disk in any form Azure ingests."
}
Write-Verbose "Rendered cloud-init passed token-substitution + secret-leak check."

# ---------------------------------------------------------------------------
# NIC: primary IPv4 ip-config (with v4 PIP) + secondary IPv6 ip-config (with v6 PIP).
# Azure does not support single-stack-IPv6 NICs; the IPv4 ip-config is mandatory.
# ---------------------------------------------------------------------------

$nic = az network nic show --name $nicName -g $rgName 2>$null | ConvertFrom-Json
if (-not $nic) {
    Write-Verbose "Creating NIC '$nicName' (primary IPv4 ip-config in '$subnetName' with PIP '$pipV4Name')"
    az network nic create `
        --name $nicName `
        --resource-group $rgName `
        --location $location `
        --subnet $snet.id `
        --public-ip-address $pipV4Name `
        --network-security-group $nsg.id `
        --tags $tags `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az network nic create '$nicName' failed." }

    Write-Verbose "Adding IPv6 ip-config '$ipcV6Name' with public IPv6 '$pipV6Name'"
    az network nic ip-config create `
        --name $ipcV6Name `
        --nic-name $nicName `
        --resource-group $rgName `
        --subnet $snet.id `
        --vnet-name $vnetName `
        --private-ip-address-version IPv6 `
        --public-ip-address $pipV6Name `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az network nic ip-config create (IPv6) failed." }
} else {
    Write-Verbose "NIC '$nicName' already present, skipping create."
}

# ---------------------------------------------------------------------------
# VM create: Ubuntu 22.04, UAMI, --attach-data-disks, custom-data cloud-init.
# CRITICAL: --attach-data-disks <disk-id>, NEVER --data-disk-sizes-gb.
# Using --data-disk-sizes-gb would create a brand-new ephemeral disk and
# undo the entire point of the standalone Managed Disk lifecycle.
# ---------------------------------------------------------------------------

$vm = az vm show --name $vmName -g $rgName 2>$null | ConvertFrom-Json
if (-not $vm) {
    $vmImage = 'Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest'
    Write-Verbose "Creating VM '$vmName' (size $VmSize, image $vmImage, UAMI '$identityName', attaching disk '$diskName')"
    az vm create `
        --resource-group $rgName `
        --name $vmName `
        --location $location `
        --size $VmSize `
        --image $vmImage `
        --os-disk-name $vmOsDisk `
        --admin-username $AdminUsername `
        --generate-ssh-keys `
        --nics $nicName `
        --assign-identity $uamiResourceId `
        --attach-data-disks $diskId `
        --custom-data $renderedPath `
        --tags $tags `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az vm create '$vmName' failed." }
} else {
    Write-Verbose "VM '$vmName' already present, skipping create."
    # Ensure the data disk is attached even on re-runs of an existing VM.
    $attachedLuns = @($vm.storageProfile.dataDisks | Where-Object { $_.managedDisk.id -eq $diskId })
    if ($attachedLuns.Count -eq 0) {
        Write-Verbose "Attaching data disk '$diskName' to existing VM '$vmName' at LUN 0"
        az vm disk attach --vm-name $vmName --resource-group $rgName --name $diskId --lun 0 --output none
        if ($LASTEXITCODE -ne 0) { throw "az vm disk attach '$diskName' failed." }
    } else {
        Write-Verbose "Data disk '$diskName' already attached to '$vmName' at LUN $($attachedLuns[0].lun)."
    }
}

# ---------------------------------------------------------------------------
# NVIDIA GPU Driver Linux extension. Installs CUDA-compatible drivers so
# vLLM can see the T4. The extension is idempotent at the resource level
# (re-applying with the same version is a no-op).
# ---------------------------------------------------------------------------

$nvidiaExtName = 'NvidiaGpuDriverLinux'
$nvidiaExt = az vm extension show --vm-name $vmName --resource-group $rgName --name $nvidiaExtName 2>$null | ConvertFrom-Json
if (-not $nvidiaExt) {
    Write-Verbose "Applying NVIDIA GPU Driver Linux extension to '$vmName'..."
    az vm extension set `
        --resource-group $rgName `
        --vm-name $vmName `
        --name $nvidiaExtName `
        --publisher Microsoft.HpcCompute `
        --version 1.10 `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az vm extension set NvidiaGpuDriverLinux failed." }
} else {
    Write-Verbose "NVIDIA GPU Driver extension already present, skipping."
}

# ---------------------------------------------------------------------------
# Auto-shutdown.
# ---------------------------------------------------------------------------

if ($ShutdownUtc) {
    Write-Verbose "Applying auto-shutdown at $ShutdownUtc UTC"
    if ($ShutdownEmail) {
        az vm auto-shutdown -g $rgName -n $vmName --time $ShutdownUtc --email $ShutdownEmail --output none
    } else {
        az vm auto-shutdown -g $rgName -n $vmName --time $ShutdownUtc --output none
    }
    if ($LASTEXITCODE -ne 0) { throw "az vm auto-shutdown failed." }
}

# ---------------------------------------------------------------------------
# Wait for cloud-init. On failure, dump /var/log/cloud-init-output.log.
# vLLM's `pip install vllm` step pulls ~3 GiB; first boot can run ~10-15min.
# ---------------------------------------------------------------------------

Write-Verbose "Waiting for cloud-init to finish on '$vmName' (~10-15 min on first boot; pip install vllm dominates)..."
$ciRaw = az vm run-command invoke `
    --resource-group $rgName `
    --name $vmName `
    --command-id RunShellScript `
    --scripts 'cloud-init status --wait && echo CLOUD_INIT_DONE' `
    --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "cloud-init poll run-command failed; output follows:"
    Write-Warning $ciRaw
    throw "cloud-init did not reach 'done' on '$vmName'."
}
$ciParsed = $ciRaw | ConvertFrom-Json -ErrorAction SilentlyContinue
$ciStdout = ($ciParsed.value | ForEach-Object { $_.message }) -join "`n"
if (-not ($ciStdout -and ($ciStdout -match 'CLOUD_INIT_DONE'))) {
    Write-Warning "cloud-init status did not return 'done'; fetching /var/log/cloud-init-output.log for context..."
    az vm run-command invoke `
        --resource-group $rgName `
        --name $vmName `
        --command-id RunShellScript `
        --scripts 'tail -n 200 /var/log/cloud-init-output.log' `
        --output table 2>&1 | Write-Host
    throw "cloud-init did not reach 'done' on '$vmName'."
}
Write-Verbose "cloud-init reported 'done'."

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------

Write-Verbose "vLLM VM deployed:"
Write-Verbose "  VM name        : $vmName"
Write-Verbose "  IPv6 FQDN      : https://$ipv6Fqdn   (cert primary; OpenCode connects here)"
Write-Verbose "  IPv4 FQDN      : https://$ipv4Fqdn   (cert SAN; fallback only)"
Write-Verbose "  Data disk      : $diskName (attached at LUN 0, persistent across rebuilds)"
Write-Verbose "  vllm.service   : enabled, INACTIVE (model not yet loaded)"
Write-Verbose ""
Write-Verbose "NEXT STEP: run util/Download-LlmModelToDisk.ps1 to populate the data disk with"
Write-Verbose "the model files. After it completes, vllm.service will start automatically."
Write-Verbose "Then run c-workload/07-Test-LlmEndpoint.ps1 to verify the endpoint."

Write-Verbose "Deploy LLM/vLLM VM complete."
