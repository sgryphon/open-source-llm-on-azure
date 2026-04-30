#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy the GPU VM that runs vLLM, with cloud-init bootstrap and the
  persistent model data disk attached.

.DESCRIPTION
  Creates, idempotently via Azure CLI, into the workload resource group:

    * Public IPv6 `pip-llm-vllm-dev-australiaeast-001`
    * Public IPv4 (if configured) `pipv4-llm-vllm-dev-australiaeast-001`
    * NIC `nic-01-vmllmvllm001-dev-001` on the LLM subnet
    * One Ubuntu 22.04 LTS GPU VM `vmllmvllm001` of size Standard_NC4as_T4_v3 (NVIDIA T4)
    * OS Disk `osdiskvmllmvllm001`

  DNS names are:
    * "vllm-<OrgId>-dev.australiaeast.cloudapp.azure.com"
    * "vllm-<OrgId>-dev-ipv4.australiaeast.cloudapp.azure.com"
 
  Enables NVIDIA GPU Driver Linux extension on the VM, and an auto shutdown schedule.
  
  No secrets are substituted into cloud-init: the API key is fetched at
  first boot by cloud-init from Key Vault using the UAMI.
  
  The model bytes are NOT downloaded by cloud-init; on success the
  `vllm.service` unit is `enabled` but `inactive` until the disk is populated.

.NOTES
  The data disk is created standalone script, and can be detached to
  rebuild the VM.

.EXAMPLE

  az login
  az account set --subscription <subscription id>
  $VerbosePreference = 'Continue'
  $env:DEPLOY_VLLM_API_KEY = 'qwen_deadbeef0001'
  ./workload/Deploy-VllmQwen.ps1
#>
[CmdletBinding()]
param (
  ## API Key to configure in vLLM (REQUIRED).
  [string]$VllmApiKey = $ENV:DEPLOY_VLLM_API_KEY,
  ## Purpose prefix.
  [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
  ## Workload prefix (matches `a-infrastructure/02-Initialize-WorkloadRg.ps1`).
  [string]$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload',
  ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
  [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
  ## Identifier for the organisation (or subscription) to make global names unique.
  [string]$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
  ## Instance number uniquifier.
  [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001',
  ## VM size. Default is the cheapest T4 SKU.
  [string]$VmSize = $ENV:DEPLOY_VM_SIZE ?? 'Standard_NV6ads_A10_v5',
  ## Linux admin account name (authentication via SSH key).
  [string]$AdminUsername = $ENV:DEPLOY_ADMIN_USERNAME ?? 'azureuser',
  ## Auto-shutdown time in UTC (HHMM). Empty string disables.
  [string]$ShutdownUtc = $ENV:DEPLOY_SHUTDOWN_UTC ?? '0900',
  ## Email to send auto-shutdown notification to (optional).
  [string]$ShutdownEmail = $ENV:DEPLOY_SHUTDOWN_EMAIL ?? '',
  ## Add a public IPv4 in addition to the IPv6. 
  [switch]$AddPublicIpv4 = ([string]::IsNullOrEmpty($ENV:DEPLOY_ADD_IPV4) -or $ENV:DEPLOY_ADD_IPV4 -eq 'true' -or $ENV:DEPLOY_ADD_IPV4 -eq '1'),
  ## Ten-character IPv6 ULA Global ID 
  [string]$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10),
  ## Two character IPv6 Unique Local Address vnet ID to use (default 02)
  [string]$VnetId = $ENV:DEPLOY_WORKLOAD_VNET_ID ?? ("02"),
  ## Two character IPv6 Unique Local Address subnet ID to use (default 00)
  [string]$SubnetId = $ENV:DEPLOY_WORKLOAD_SUBNET_ID ?? ("00"),
  ## Disk size in GiB. 8 GiB is enough for one AWQ-INT4 7B model with headroom.
  [int]$DiskSizeGiB = [int]($ENV:DEPLOY_LLM_DISK_GIB ?? 8),
  ## Managed disk SKU.
  [ValidateSet('Standard_LRS', 'StandardSSD_LRS', 'Premium_LRS')]
  [string]$DiskSku = $ENV:DEPLOY_LLM_DISK_SKU ?? 'StandardSSD_LRS',
  ## Pinned vLLM version. Change deliberately; vLLM CLI flags drift between minors.
  [string]$VllmVersion = $ENV:DEPLOY_VLLM_VERSION ?? '0.20.0',
  ## Mount point for the data disk on the VM.
  [string]$ModelMountPoint = $ENV:DEPLOY_MODEL_MOUNT_POINT ?? '/opt/models',
  ## Subdirectory under the model mount where the model files live.
  [string]$ModelDirName = $ENV:DEPLOY_MODEL_DIR_NAME ?? 'qwen2.5-coder-7b-awq',
  ## Served model name (the `id` returned by `/v1/models` and used in chat requests).
  [string]$ServedModelName = $ENV:DEPLOY_SERVED_MODEL_NAME ?? 'qwen2.5-coder-7b'
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$VllmApiKey = 'qwen_deadbeef0001'
$Purpose = 'LLM'
$Workload = 'workload'
$Environment = 'Dev'
$OrgId = "0x$((az account show --query id --output tsv).Substring(0,4))"
$Instance = '001'
$VmSize = 'Standard_NC4as_T4_v3'
$AdminUsername = 'azureuser'
$ShutdownUtc = '0900'
$ShutdownEmail = ''
$AddPublicIpv4 = $true

$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10)
$VnetId = $ENV:DEPLOY_WORKLOAD_VNET_ID ?? ("02")
$SubnetId = $ENV:DEPLOY_WORKLOAD_SUBNET_ID ?? ("00")

$DiskSizeGiB = [int]($ENV:DEPLOY_LLM_DISK_GIB ?? 8)
$DiskSku = $ENV:DEPLOY_LLM_DISK_SKU ?? 'StandardSSD_LRS'

$VllmVersion = '0.6.4'
$ModelMountPoint = '/opt/models'
$ModelDirName = 'qwen2.5-coder-7b-awq'
$ServedModelName = 'qwen2.5-coder-7b'
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($VllmApiKey)) {
  throw 'You must supply a value for -VllmApiKey or set environment variable DEPLOY_VLLM_API_KEY.'
}

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying vLLM $Instance for environment '$Environment' in subscription '$SubscriptionId'"
# ---------------------------------------------------------
# Names

$rgName = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$rg = az group show --name $rgName 2>$null | ConvertFrom-Json
$location = $rg.location

$appName = 'vllm'
$diskAppName = "model"

$nsgName = "nsg-$Purpose-workload-$Environment-001".ToLowerInvariant()
$subnetName = "snet-$Purpose-workload-$Environment-$location-001".ToLowerInvariant()

$vmName = "vm$appName$Environment$Instance".ToLowerInvariant()
$identityName = "id-$vmName".ToLowerInvariant()
$diskName = "disk$diskAppName$Environment$Instance".ToLowerInvariant()
$pipV6Name = "pip-$vmName-$location-01".ToLowerInvariant()
$pipV4Name = "pipv4-$vmName-$location-01".ToLowerInvariant()
$nicName = "nic-$vmName-01".ToLowerInvariant()
$vmOsDisk = "osdisk$vmName".ToLowerInvariant()

Write-Verbose "Network Security Group: $nsgName"
Write-Verbose "Managed Identity: $identityName"
Write-Verbose "Model Disk: $diskName"
Write-Verbose "Public IP: $pipV6Name"
Write-Verbose "Public IP: $pipV4Name"
Write-Verbose "Network Interface: $nicName"
Write-Verbose "Virtual Machine: $vmName"
Write-Verbose "OS Disk: $vmOsDisk"
Write-Verbose "Subnet: $subnetName"

# ---------------------------------------------------------
# Other values

# Networking
$vnetName = "vnet-$Purpose-$Workload-$Environment-$location-$Instance".ToLowerInvariant()

# Global will default to unique value per subscription
$prefixV6 = "fd$($UlaGlobalId.Substring(0, 2)):$($UlaGlobalId.Substring(2, 4)):$($UlaGlobalId.Substring(6, 4))"
$subnetAddressV6 = [IPAddress]"$($prefixV6):$($VnetId)$($SubnetId)::"
$subnetV6 = "$subnetAddressV6/64"

# Azure only supports dual-stack (not single stack IPv6)
# "At least one IPv4 ipConfiguration is required for an IPv6 ipConfiguration on the network interface"

# Use the first byte of the ULA Global ID, and the vnet ID (as decimal)
$prefixByte = [int]"0x$($UlaGlobalId.Substring(0, 2))"
$decVnet = [int]("0x$VnetId" -bAnd 0xf) -shl 4
$decSubnet = [int]("0x$SubnetId" -bAnd 0xf)
$subnetAddressV4 = [IPAddress]"10.$prefixByte.$($decVnet + $decSubnet).0"
$subnetV4 = "$subnetAddressV4/24"

# KV, to assign identity permissions
$coreRgName = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$kvName = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()

# Public DNS
$pipV6DnsName = "llm-$OrgId-$Environment-$Instance".ToLowerInvariant()
$pipV4DnsName = "llm-$OrgId-$Environment-$Instance-ipv4".ToLowerInvariant()

# Network interface details
$ipcV4Name = 'ipconfig1'  # Azure auto-creates this on the NIC; we update it.
$ipcV6Name = "ipc-v6-$vmName-$Environment-$Instance".ToLowerInvariant()

# Following standard tagging conventions from  Azure Cloud Adoption Framework
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging

$TagDictionary = [ordered]@{
  WorkloadName       = $Workload
  ApplicationName    = $appName
  DataClassification = 'Non-business'
  Criticality        = 'Low'
  BusinessUnit       = $Purpose
  Env                = $Environment
}
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

# ---------------------------------------------------------
# Network Security Group

$nsg = az network nsg show --name $nsgName -g $rgName 2>$null | ConvertFrom-Json
if (-not $nsg) {
  Write-Verbose "Creating network security group $nsgName"
  az network nsg create --name $nsgName -g $rgName -l $location --tags $tags
  if ($LASTEXITCODE -ne 0) { throw "create network security group failed." }

  Write-Verbose "Adding Network security group rule 'AllowSSH' for port 22 to $nsgName"
  az network nsg rule create --name AllowSSH `
    --nsg-name $nsgName `
    --priority 1000 `
    --resource-group $rgName `
    --access Allow `
    --source-address-prefixes "*" `
    --source-port-ranges "*" `
    --direction Inbound `
    --destination-port-ranges 22

  Write-Verbose "Adding Network security group rule 'AllowICMP' for ICMP to $nsgName"
  az network nsg rule create --name AllowICMPv4 `
    --nsg-name $nsgName `
    --priority 1001 `
    --resource-group $rgName `
    --access Allow `
    --source-address-prefixes "*" `
    --direction Inbound `
    --destination-port-ranges "*" `
    --protocol Icmp

  # Can't create ICMPv6 via API.
  # If you create a rule, then you can update it via the UI.

  Write-Verbose "Adding Network security group rule 'AllowHTTP' for port 80, 443 to $nsgName"
  az network nsg rule create --name AllowHTTP `
    --nsg-name $nsgName `
    --priority 1003 `
    --resource-group $rgName `
    --access Allow `
    --source-address-prefixes "*" `
    --source-port-ranges "*" `
    --direction Inbound `
    --destination-port-ranges 80 443

  # Check rules
  # az network nsg rule list --nsg-name $nsgDmzName --resource-group $rgName
}
else {
  Write-Verbose "Network Security Group already exists"
}

# ---------------------------------------------------------
# Subnet

$subnet = az network vnet subnet show --name $subnetName -g $rgName --vnet-name $vnetName 2>$null | ConvertFrom-Json
if (-not $subnet) {
  Write-Verbose "Creating subnet $subnetName ($subnetV6, $subnetV4)"
  $subnet = az network vnet subnet create --name $subnetName `
    --address-prefix $subnetV6 $subnetV4 `
    --resource-group $rgName `
    --vnet-name $vnetName `
    --network-security-group $nsgName | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw "create subnet failed." }
}
else {
  Write-Verbose "Subnet already exists"
}

# ---------------------------------------------------------
# Managed Identity

$identity = az identity show --name $identityName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $identity) {
  Write-Verbose "Creating managed identity '$identityName'"
  $identity = az identity create `
    --name $identityName `
    --resource-group $rgName `
    --location $location `
    --tags $tags | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $identity) {
    throw "az identity create failed for '$identityName'"
  }

  $principalId = $identity.principalId
  Write-Verbose "Granting 'get, list' secret permissions on '$kvName' to identity '$identityName' ($principalId)"
  az keyvault set-policy `
    --name $kvName `
    --resource-group $coreRgName `
    --object-id $principalId `
    --secret-permissions get list `
    --output none
  if ($LASTEXITCODE -ne 0) { throw "az keyvault set-policy failed for identity '$identityName' on '$kvName'" }
}
else {
  Write-Verbose "Managed Identity already exists"
}
$uamiResourceId = $identity.id
$uamiClientId = $identity.clientId

# ---------------------------------------------------------
# Model Data Disk

$disk = az disk show --name $diskName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $disk) {
  Write-Verbose "Creating managed disk '$diskName' (${DiskSizeGiB} GiB, $DiskSku, empty)"
  $disk = az disk create `
    --name $diskName `
    --resource-group $rgName `
    --location $location `
    --size-gb $DiskSizeGiB `
    --sku $DiskSku `
    --tags $tags | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw "az disk create '$diskName' failed." }
}
else {
  Write-Verbose "Models Data Disk already exists"
}
$diskId = $disk.id

# ---------------------------------------------------------
# Public IP addresses

$pipV6 = az network public-ip show --name $pipV6Name --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $pipV6) {
  Write-Verbose "Creating Public IP addresses $pipV6Name (DNS $pipV6DnsName)"
  az network public-ip create `
    --name $pipV6Name  `
    --dns-name $pipV6DnsName `
    --resource-group $rgName `
    --location $location `
    --sku Standard  `
    --allocation-method static  `
    --version IPv6 `
    --tags $tags
}
else {
  Write-Verbose "Public IPv6 already exists"
}

if ($AddPublicIpv4) {
  $pipV4 = az network public-ip show --name $pipV4Name --resource-group $rgName 2>$null | ConvertFrom-Json
  if (-not $pipV4) {
    Write-Verbose "Creating Public IPv4 addresses $pipV4Name (DNS $pipV4DnsName)"
    az network public-ip create `
      --name $pipV4Name  `
      --dns-name $pipV4DnsName `
      --resource-group $rgName `
      --location $location  `
      --sku Standard  `
      --allocation-method static  `
      --version IPv4 `
      --tags $tags
  }
  else {
    Write-Verbose "Public IPv4 already exists"
  }
}

# Get the fully qualified domain names (from the public IPs)
$fqdnV6 = $(az network public-ip show --name $pipV6Name --resource-group $rgName --query dnsSettings.fqdn --output tsv)
$fqdnList = @($fqdnV6)
if ($AddPublicIpv4) {
  $fqdnV4 = $(az network public-ip show --name $pipv4Name --resource-group $rgName --query dnsSettings.fqdn --output tsv)
  $fqdnList += $fqdnV4
}
$fqdnJoinedList = $($fqdnList -join ', ')
$certEmail = "postmaster@$fqdnV6"

Write-Verbose "FQDN: $fqdnJoinedList"

# ---------------------------------------------------------
# Network Interface

$nic = az network nic show --name $nicName -g $rgName 2>$null | ConvertFrom-Json
if (-not $nic) {
  # Azure only supports dual stack; primary NIC IP config must be IPv4

  Write-Verbose "Creating Network interface controller $nicName (required IPv4)"
  az network nic create `
    --name $nicName `
    --resource-group $rgName `
    --subnet $subnet.Id `
    --tags $tags
  if ($LASTEXITCODE -ne 0) { throw "az network nic create '$nicName' failed." }

  Write-Verbose "Adding NIC IP Config $ipcV6Name ($pipV6Name) to $nicName"
  az network nic ip-config create `
    --name $ipcV6Name `
    --nic-name $nicName  `
    --resource-group $rgName `
    --subnet $subnet.Id `
    --private-ip-address-version IPv6 `
    --public-ip-address $pipV6Name
  if ($LASTEXITCODE -ne 0) { throw "az network nic ip-config create (IPv6) failed." }

  if ($AddPublicIpv4) {
    # the auto-created config name is ipconfig1
    az network nic ip-config update `
      --name $ipcV4Name `
      --nic-name $nicName `
      -g $rgName `
      --public-ip-address $pipV4Name
  }

  # Azure-level IP forwarding
  Write-Verbose "Ensuring --ip-forwarding=true on NIC '$nicName'"
  az network nic update --name $nicName --resource-group $rgName --ip-forwarding true --output none
  if ($LASTEXITCODE -ne 0) { throw "az network nic update --ip-forwarding failed." }
}
else {
  Write-Verbose "Network interface already exists"
}

# ---------------------------------------------------------
# Check Machine Quota

# Check Quota: standardNCASv3Family covers Standard_NC4as_T4_v3 / NC8as_T4_v3 / NC16as_T4_v3 / NC64as_T4_v3.

if ($VmSize -eq 'Standard_NV6ads_A10_v5') {
  $vmFamily = 'StandardNVADSA10v5Family'
  $cpuRequired = 6
}
else {
  throw "Unknown VmSize $VmSize"
}

Write-Verbose "Checking GPU quota for '$vmFamily' in '$($location)'..."
# $usage = az vm list-usage --location australiaeast --output json 2>$null | ConvertFrom-Json
# $usage | Where-Object { $_.limit -gt $_.currentValue } | Where-Object { $_.localName -cmatch 'N(C|D|V)'}
# az vm list-skus --location australiaeast --size Standard_NV
# Apr 2026
# Best StandardNCadsH100v5Family: Standard_NC40ads_H100_v5, Standard_NC80ads_H100_v5
# Practical StandardNVADSA10v5Family: Standard_NV6ads_A10_v5, Standard_NV12ads_A10_v5, Standard_NV36ads_A10_v5=
$quota = az vm list-usage --location $location --query "[?name.value=='$vmFamily'] | [0]" --output json 2>$null | ConvertFrom-Json
if ($quota) {
  Write-Verbose "  current usage: $($quota.currentValue) / limit: $($quota.limit)"
  $cpuAvailable = $quota.limit - $quota.currentValue
  if ([int]$cpuAvailable -lt $cpuRequired) {
    throw @"
GPU quota '$vmFamily' in '$location' is $($quota.limit). $VmSize needs $cpuRequired vCPUs.
Request a quota increase: https://learn.microsoft.com/azure/quotas/per-vm-quota-requests
"@
  }
}
else {
  throw @"
Could not read '$vmFamily' quota for '$location' (the quota family may not be exposed in this region). $VmSize needs $cpuRequired vCPUs.
"@
}

# TODO: Check SKU available

# ---------------------------------------------------------
# Virtual Machine

$vm = az vm show --name $vmName -g $rgName 2>$null | ConvertFrom-Json
if (-not $vm) {

  # Render cloud-init (substitute #INIT_*# tokens, write to ./temp/...~).

  $tempDir = Join-Path $PSScriptRoot 'temp'
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
  $tempDir = (Resolve-Path $tempDir).ProviderPath
  $templatePath = Join-Path $PSScriptRoot 'data' 'vllm-cloud-init.txt'
  $renderedPath = Join-Path $tempDir     'vllm-cloud-init.txt~'

  Write-Verbose "Rendering cloud-init from '$templatePath' -> '$renderedPath'"
  # Use literal .Replace() (not PS -replace) so any regex metacharacters in
  # substituted values pass through unchanged.
  $rendered = (Get-Content -Path $templatePath -Raw)
  $subs = [ordered]@{
    '#INIT_HOST_NAMES#'        = $fqdnJoinedList
    '#INIT_API_KEY#'           = $VllmApiKey
    '#INIT_CERT_EMAIL#'        = $certEmail
    '#INIT_VLLM_VERSION#'      = $VllmVersion
    '#INIT_SERVED_MODEL_NAME#' = $ServedModelName
    '#INIT_MODEL_DIR_NAME#'    = $ModelDirName
    '#INIT_MODEL_MOUNT_POINT#' = $ModelMountPoint
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

  # VM create: Ubuntu 22.04, UAMI, --attach-data-disks, custom-data cloud-init.

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
}
else {
  Write-Verbose "VM '$vmName' already present, skipping create."
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
}
else {
  Write-Verbose "NVIDIA GPU Driver extension already present, skipping."
}

# ---------------------------------------------------------------------------
# Auto-shutdown.
# ---------------------------------------------------------------------------

if ($ShutdownUtc) {
  Write-Verbose "Applying auto-shutdown at $ShutdownUtc UTC"
  if ($ShutdownEmail) {
    az vm auto-shutdown -g $rgName -n $vmName --time $ShutdownUtc --email $ShutdownEmail --output none
  }
  else {
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
$ciStdout = ($ciParsed.value | ForEach-Object { "$($_.message)" }) -join "`n"
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
# To check: ssh llm-0x419d-dev-001.australiaeast.cloudapp.azure.com
Write-Verbose "cloud-init reported 'done'."

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------

Write-Verbose "vLLM VM deployed:"

$vm = (az vm show --name $vmName -g $rgName -d) | ConvertFrom-Json
$vm | Format-List name, fqdns, publicIps, privateIps, location, hardwareProfile
Write-Verbose "  Data disk      : $diskName (attached at LUN 0, persistent across rebuilds)"
Write-Verbose "  vllm.service   : enabled, INACTIVE (model not yet loaded)"
Write-Verbose ""
Write-Verbose "NEXT STEP: run util/Import-LlmModel.ps1 to populate the data disk with"
Write-Verbose "the model files. After it completes, vllm.service will start automatically."
