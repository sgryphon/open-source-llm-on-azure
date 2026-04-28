#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy an Ubuntu VM running strongSwan as an IKEv2 road-warrior VPN gateway.

.DESCRIPTION
  Creates, idempotently via Azure CLI, into the shared core resource group and
  gateway subnet produced by earlier scripts:

    * Two NSG rules on the existing gateway NSG (`AllowIKE`, `AllowIPsecNatT`).
    * One public IPv6 (Standard SKU, static), and optionally one public IPv4.
    * One NIC with a primary IPv4 ip-config + a secondary IPv6 ip-config,
      attached to the gateway subnet, with Azure-level IP forwarding enabled.
    * One Ubuntu LTS VM bound to the shared user-assigned managed identity
      `id-<Purpose>-strongswan-<Environment>-<Instance>` (created by an
      earlier VPN-identity script) and a rendered cloud-init payload from
      `data/strongswan-cloud-init.txt`.
    * An optional auto-shutdown schedule.

  The rendered cloud-init file pulls the CA cert, server cert, and server
  private key from Key Vault at first boot and brings up the strongSwan
  service with one road-warrior connection accepting both EAP-MSCHAPv2 and
  client-certificate auth.

.NOTES
  IPv6 FQDN = "strongswan-<OrgId>-<Environment>.<Location>.cloudapp.azure.com"
  IPv4 FQDN = "strongswan-<OrgId>-<Environment>-ipv4.<Location>.cloudapp.azure.com"

  VPN CLIENT POOL ADDRESSING
  The VPN client IP pool is a pure strongSwan construct (no Azure VNet /
  subnet is created for it). Addresses are derived deterministically from
  `-UlaGlobalId` (the same hash used by the gateway-subnet script) and
  `-VpnVnetId` (default `02`). For a ULA Global ID decomposed as
  `gg gggg gggg`:

      IPv4 subnet  = 10.<gg-dec>.<VpnVnetId-dec>.0/24
      IPv4 pool    = upper /25 of the subnet (e.g. 10.171.2.128/25)
      IPv6 subnet  = fd<gg>:<gggg>:<gggg>:<VpnVnetId>00::/64
      IPv6 pool    = ::1000/116 inside the subnet (4096 addresses)

  EAP PASSWORD
  `-VpnUserPassword` (env `DEPLOY_VPN_USER_PASSWORD`) is required. It is NOT
  stored in Key Vault in this MVP; it is baked into `/etc/swanctl/conf.d/
  secrets.conf` on the VM (root-read-only). Treat shell history accordingly.

  CONVENTIONS
  Follows the Azure CAF naming and tagging conventions.

.EXAMPLE

  az login
  az account set --subscription <subscription id>
  $VerbosePreference = 'Continue'
  $env:DEPLOY_VPN_USER_PASSWORD = 'P@ssword01'
  ./b-shared/06-Deploy-StrongSwanVm.ps1
#>
[CmdletBinding()]
param (
    ## EAP-MSCHAPv2 password (REQUIRED).
    [string]$VpnUserPassword = $ENV:DEPLOY_VPN_USER_PASSWORD,
    ## EAP-MSCHAPv2 username seeded into swanctl secrets.
    [string]$VpnUsername = $ENV:DEPLOY_VPN_USERNAME ?? 'vpnuser',
    ## Purpose prefix (matches the shared Key Vault / gateway-subnet scripts).
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## Identifier for the organisation (or subscription) to make global names unique.
    [string]$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
    ## Instance number uniquifier for the shared RG / Key Vault.
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001',
    ## VM size. Default matches the project's dev-tier sizing.
    [string]$VmSize = $ENV:DEPLOY_VM_SIZE ?? 'Standard_D2s_v6',
    ## Linux admin account name (authentication via SSH key).
    [string]$AdminUsername = $ENV:DEPLOY_ADMIN_USERNAME ?? 'azureuser',
    ## Auto-shutdown time in UTC, default 0900 = 19:00 in Brisbane. Empty string disables.
    [string]$ShutdownUtc = $ENV:DEPLOY_SHUTDOWN_UTC ?? '0900',
    ## Email to send auto-shutdown notification to (optional).
    [string]$ShutdownEmail = $ENV:DEPLOY_SHUTDOWN_EMAIL ?? '',
    ## Add a public IPv4 in addition to the IPv6. MUST match the gateway-subnet run.
    [switch]$AddPublicIpv4 = ([string]::IsNullOrEmpty($ENV:DEPLOY_ADD_IPV4) -or $ENV:DEPLOY_ADD_IPV4 -eq 'true' -or $ENV:DEPLOY_ADD_IPV4 -eq '1'),
    ## Ten-character IPv6 ULA Global ID (MUST match the gateway-subnet script).
    [string]$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10),
    ## Two character IPv6 Unique Local Address vnet ID to use for core subnet (default 03)
    [string]$PoolVnetId = $ENV:DEPLOY_POOL_VNET_ID ?? ("03"),
    ## Two character subnet id for VPN clients (default 00)
    [string]$PoolSubnetId = $ENV:DEPLOY_POOL_SUBNET_ID ?? '00'
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))"
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
$VmSize = $ENV:DEPLOY_VM_SIZE ?? 'Standard_D2s_v6'
$AdminUsername = $ENV:DEPLOY_ADMIN_USERNAME ?? 'azureuser'
$VpnUsername = $ENV:DEPLOY_VPN_USERNAME ?? 'vpnuser'
$VpnUserPassword = $ENV:DEPLOY_VPN_USER_PASSWORD
$VpnVnetId = $ENV:DEPLOY_VPN_VNET_ID ?? '02'
$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10)
$ShutdownUtc = '0900'
$ShutdownEmail = ''
$AddPublicIpv4 = $true
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($VpnUserPassword)) {
    throw 'You must supply a value for -VpnUserPassword or set environment variable DEPLOY_VPN_USER_PASSWORD.'
}

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying strongSwan VM for environment '$Environment' in subscription '$SubscriptionId'$($AddPublicIpv4 ? ' with IPv4' : '')"

$appName   = 'strongswan'
$vmName    = "vm$appName$Instance".ToLowerInvariant()

# Resolve the shared RG, VNet, gateway subnet, gateway NSG, Key Vault.
$rgName            = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$rg                = az group show --name $rgName 2>$null | ConvertFrom-Json
if (-not $rg) { throw "Resource group '$rgName' not found." }
$location          = $rg.location
$locationLower     = $location.ToLowerInvariant()

$vnetName          = "vnet-$Purpose-hub-$location-$Instance".ToLowerInvariant()
$gatewayNsgName    = "nsg-$Purpose-gateway-$Environment-001".ToLowerInvariant()
$gatewaySubnetName = "snet-$Purpose-gateway-$Environment-$location-001".ToLowerInvariant()

$vnet    = az network vnet show --name $vnetName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $vnet) { throw "VNet '$vnetName' not found." }

$gwSnet  = az network vnet subnet show --name $gatewaySubnetName -g $rgName --vnet-name $vnetName 2>$null | ConvertFrom-Json
if (-not $gwSnet) { throw "Gateway subnet '$gatewaySubnetName' not found." }

$gwNsg   = az network nsg show --name $gatewayNsgName -g $rgName 2>$null | ConvertFrom-Json
if (-not $gwNsg) { throw "Gateway NSG '$gatewayNsgName' not found." }

$kvName  = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()
$kv      = az keyvault show --name $kvName 2>$null | ConvertFrom-Json
if (-not $kv) { throw "Key Vault '$kvName' not found." }

# Resolve the shared VPN user-assigned managed identity.
$identityName = "id-$vmName-$Environment".ToLowerInvariant()
$identity     = az identity show --name $identityName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $identity) {
    throw "Managed identity '$identityName' not found."
}
$uamiResourceId = $identity.id
$uamiClientId   = $identity.clientId
if (-not $uamiResourceId -or -not $uamiClientId) {
    throw "Managed identity '$identityName' is missing an id or clientId."
}
Write-Verbose "Resolved shared resources: RG=$rgName, VNet=$vnetName, Subnet=$gatewaySubnetName, NSG=$gatewayNsgName, KV=$kvName, UAMI=$identityName"

# Derived names and addressing.
$vmOsDisk  = "osdisk$vmName".ToLowerInvariant()
$nicName   = "nic-01-$vmName-$Environment-$Instance".ToLowerInvariant()
$ipcV4Name = 'ipconfig1'  # Azure auto-creates this on the NIC; we update it.
$ipcV6Name = "ipc-v6-$vmName-$Environment-$Instance".ToLowerInvariant()
$pipV6Name = "pip-$vmName-$Environment-$location-$Instance".ToLowerInvariant()
$pipV4Name = "pipv4-$vmName-$Environment-$location-$Instance".ToLowerInvariant()

$ServerDnsLabel = "strongswan-$OrgId-$Environment".ToLowerInvariant()
$pipV6DnsLabel = $ServerDnsLabel.ToLowerInvariant()
$pipV4DnsLabel = "$ServerDnsLabel-ipv4".ToLowerInvariant()

# Derive IPv6 / IPv4 PIP FQDNs from parameters
$ipv6Fqdn = "$pipV6DnsLabel.$locationLower.cloudapp.azure.com"
$ipv4Fqdn = "$pipV4DnsLabel.$locationLower.cloudapp.azure.com"
$fqdnList = @($ipv6Fqdn)
if ($AddPublicIpv4) { $fqdnList += $ipv4Fqdn }
Write-Verbose "Server FQDNs: $($fqdnList -join ', ')"

# VPN client pool addressing
# The substituted values flow into cloud-init.
# UlaGlobalId = gg gggg gggg (10 hex chars). VpnVnetId is 2 hex chars.
$prefix = "fd$($UlaGlobalId.Substring(0, 2)):$($UlaGlobalId.Substring(2, 4)):$($UlaGlobalId.Substring(6))"

# IPv6 subnet: fd<gg>:<gggg>:<gggg>:<VpnVnetId>::/64
$poolSubnetAddress = [IPAddress]"$($prefix):$($PoolVnetId)$($PoolSubnetId)::"
$poolSubnetIpPrefix = "$poolSubnetAddress/64"

# IPv6 pool: /116 at ::1000 inside the /64.
$poolBase    = [IPAddress]"$($prefix):$($PoolVnetId)$($PoolSubnetId)::1000"
$vipPoolIPv6 = "$poolBase/116"

# IPv4: 10.<ggDec>.<vpnVnetDec>.0/24 ; pool = upper half /25 at .128.
$prefixByte = [int]"0x$($UlaGlobalId.Substring(0, 2))"
$decVnet = [int]("0x$PoolVnetId" -bAnd 0xf) -shl 4
$decSubnet = [int]("0x$PoolSubnetId" -bAnd 0xf)

$poolSubnetIPv4 = "10.$prefixByte.$($decVnet + $decSubnet).0/24"
$vipPoolIPv4    = "10.$prefixByte.$($decVnet + $decSubnet).128/25"

Write-Verbose "VPN subnets: IPv6=$poolSubnetAddress, IPv4=$poolSubnetIPv4"
Write-Verbose "VPN pools  : IPv6=$vipPoolIPv6, IPv4=$vipPoolIPv4"
# ---------------------------------------------------------------------------

# Secret names must match those written by the certificate-deployment script.
$envLower              = $Environment.ToLowerInvariant()
$secretPrefix          = "strongswan-$envLower"
$caSecretName          = "$secretPrefix-ca-cert"
$serverCertSecretName  = "$secretPrefix-server-cert"
$serverKeySecretName   = "$secretPrefix-server-key"
$clientP12SecretName   = "$secretPrefix-client-001-p12"
$clientP12PwdSecretName= "$secretPrefix-client-001-p12-password"

Write-Verbose "Verifying Key Vault secrets from the certificate-deployment script ..."
foreach ($name in @($caSecretName, $serverCertSecretName, $serverKeySecretName)) {
    $s = az keyvault secret show --vault-name $kvName --name $name 2>$null | ConvertFrom-Json
    if (-not ($s -and $s.value)) {
        throw "Key Vault secret '$name' is missing in '$kvName'."
    }
    Write-Verbose "  OK: $name"
}

# Tag dictionary matching the gateway-subnet script's style.
$TagDictionary = [ordered]@{
    DataClassification = 'Non-business'
    Criticality        = 'Low'
    BusinessUnit       = $Purpose
    ApplicationName    = $appName
    Env                = $Environment
}
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

# NSG rules: AllowIKE (2100, UDP 500), AllowIPsecNatT (2101, UDP 4500).
function Add-NsgRuleIfAbsent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Priority,
        [Parameter(Mandatory)][string]$DestPort
    )
    $existing = az network nsg rule show --nsg-name $gatewayNsgName -g $rgName -n $Name 2>$null | ConvertFrom-Json
    if ($existing) {
        Write-Verbose "NSG rule '$Name' already present, skipping."
        return
    }
    Write-Verbose "Adding NSG rule '$Name' (priority $Priority, UDP port $DestPort)"
    az network nsg rule create --name $Name `
                               --nsg-name $gatewayNsgName `
                               --priority $Priority `
                               --resource-group $rgName `
                               --access Allow `
                               --source-address-prefixes '*' `
                               --source-port-ranges '*' `
                               --direction Inbound `
                               --protocol Udp `
                               --destination-port-ranges $DestPort `
                               --output none
    if ($LASTEXITCODE -ne 0) { throw "az network nsg rule create '$Name' failed." }
}

Add-NsgRuleIfAbsent -Name 'AllowIKE'        -Priority 2100 -DestPort '500'
Add-NsgRuleIfAbsent -Name 'AllowIPsecNatT'  -Priority 2101 -DestPort '4500'

Write-Verbose "NSG rules on ${gatewayNsgName}:"
az network nsg rule list --nsg-name $gatewayNsgName -g $rgName --query "[?name=='AllowIKE' || name=='AllowIPsecNatT'].{name:name,priority:priority,protocol:protocol,dest:destinationPortRange}" --output tsv | ForEach-Object { Write-Verbose "  $_" }

# Public IPs + NIC (idempotent).
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
    Write-Verbose "Creating public IP '$Name' ($Version, DNS '$DnsLabel')"
    az network public-ip create `
      --name $Name `
      --dns-name $DnsLabel `
      --resource-group $rgName `
      --location $location `
      --sku Standard `
      --allocation-method static `
      --version $Version `
      --tags $tags `
      --output none
    if ($LASTEXITCODE -ne 0) { throw "az network public-ip create '$Name' failed." }
}

Ensure-PublicIp -Name $pipV6Name -DnsLabel $pipV6DnsLabel -Version IPv6
if ($AddPublicIpv4) {
    Ensure-PublicIp -Name $pipV4Name -DnsLabel $pipV4DnsLabel -Version IPv4
}

# NIC: primary IPv4 ip-config + secondary IPv6 ip-config on the gateway subnet.
$nic = az network nic show --name $nicName -g $rgName 2>$null | ConvertFrom-Json
if (-not $nic) {
    Write-Verbose "Creating NIC '$nicName' (primary IPv4 in gateway subnet)"
    $nicCreateArgs = @(
        'network','nic','create',
        '--name', $nicName,
        '--resource-group', $rgName,
        '--subnet', $gwSnet.id,
        '--tags'
    ) + $tags
    if ($AddPublicIpv4) {
        $nicCreateArgs += @('--public-ip-address', $pipV4Name)
    }
    az @nicCreateArgs --output none
    if ($LASTEXITCODE -ne 0) { throw "az network nic create '$nicName' failed." }

    Write-Verbose "Adding IPv6 ip-config '$ipcV6Name' with public IPv6 '$pipV6Name'"
    az network nic ip-config create `
      --name $ipcV6Name `
      --nic-name $nicName `
      --resource-group $rgName `
      --subnet $gwSnet.id `
      --private-ip-address-version IPv6 `
      --public-ip-address $pipV6Name `
      --output none
    if ($LASTEXITCODE -ne 0) { throw "az network nic ip-config create (IPv6) failed." }
} else {
    Write-Verbose "NIC '$nicName' already present, skipping create."
}

# Azure-level IP forwarding (always ensure, idempotent).
Write-Verbose "Ensuring --ip-forwarding=true on NIC '$nicName'"
az network nic update --name $nicName --resource-group $rgName --ip-forwarding true --output none
if ($LASTEXITCODE -ne 0) { throw "az network nic update --ip-forwarding failed." }

# Render cloud-init.
$tempDir = Join-Path $PSScriptRoot 'temp'
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$tempDir = (Resolve-Path $tempDir).ProviderPath
$templatePath = Join-Path $PSScriptRoot 'data' 'strongswan-cloud-init.txt'
$renderedPath = Join-Path $tempDir     'strongswan-cloud-init.txt~'

Write-Verbose "Rendering cloud-init from '$templatePath' -> '$renderedPath'"
$serverFqdnsJoined = ($fqdnList -join ',')
# Use literal string .Replace() (not PS -replace) so regex metacharacters in
# the password (e.g. '$') pass through unchanged.
$rendered = (Get-Content -Path $templatePath -Raw)
$subs = [ordered]@{
    '#INIT_VPN_USERNAME#'            = $VpnUsername
    '#INIT_VPN_PASSWORD#'            = $VpnUserPassword
    '#INIT_VPN_SUBNET_IPV6#'         = $poolSubnetIpPrefix
    '#INIT_VPN_SUBNET_IPV4#'         = $poolSubnetIPv4
    '#INIT_VIP_POOL_IPV6#'           = $vipPoolIPv6
    '#INIT_VIP_POOL_IPV4#'           = $vipPoolIPv4
    '#INIT_SERVER_FQDNS#'            = $serverFqdnsJoined
    '#INIT_KEY_VAULT_NAME#'          = $kvName
    '#INIT_CA_SECRET_NAME#'          = $caSecretName
    '#INIT_SERVER_CERT_SECRET_NAME#' = $serverCertSecretName
    '#INIT_SERVER_KEY_SECRET_NAME#'  = $serverKeySecretName
    '#INIT_ADMIN_USER#'              = $AdminUsername
    '#INIT_UAMI_CLIENT_ID#'          = $uamiClientId
}
foreach ($k in $subs.Keys) {
    $rendered = $rendered.Replace($k, [string]$subs[$k])
}
Set-Content -Path $renderedPath -Value $rendered -NoNewline

# Post-render assertion: no `#INIT_*#` tokens remain.
$leftover = [regex]::Matches($rendered, '#INIT_[A-Z_]+#')
if ($leftover.Count -gt 0) {
    throw "Unsubstituted cloud-init tokens remain: $(($leftover | ForEach-Object { $_.Value }) -join ', ')"
}
Write-Verbose "Rendered cloud-init passed token-substitution check."

# VM create + user-assigned managed identity binding + auto-shutdown.

$vm = az vm show --name $vmName -g $rgName 2>$null | ConvertFrom-Json
if (-not $vm) {
    # Image: Canonical Ubuntu 22.04 LTS (Jammy), Gen2. The legacy `UbuntuLTS`
    # alias was retired by Azure CLI in 2023; use the explicit URN.
    $vmImage = 'Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest'
    Write-Verbose "Creating VM '$vmName' (size $VmSize, image $vmImage, UAMI '$identityName')"
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
        --custom-data $renderedPath `
        --tags $tags `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az vm create '$vmName' failed." }
} else {
    Write-Verbose "VM '$vmName' already present, skipping create."
}

if ($ShutdownUtc) {
    Write-Verbose "Applying auto-shutdown at $ShutdownUtc UTC"
    if ($ShutdownEmail) {
        az vm auto-shutdown -g $rgName -n $vmName --time $ShutdownUtc --email $ShutdownEmail --output none
    } else {
        az vm auto-shutdown -g $rgName -n $vmName --time $ShutdownUtc --output none
    }
    if ($LASTEXITCODE -ne 0) { throw "az vm auto-shutdown failed." }
}

# Post-deploy verification + operator output.
Write-Verbose "Waiting for cloud-init to finish on '$vmName' (this can take several minutes on first boot)..."
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
# Azure CLI run-command output shapes vary by CLI version:
# Accept either: grab every `message` field and match against the sentinel.
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

# Summary output.
Write-Verbose "strongSwan VPN VM deployed:"
Write-Verbose "  VM name        : $vmName"
Write-Verbose "  IPv6 FQDN      : $ipv6Fqdn"
if ($AddPublicIpv4) {
    Write-Verbose "  IPv4 FQDN      : $ipv4Fqdn"
}
$pipV6 = az network public-ip show --name $pipV6Name -g $rgName --query ipAddress --output tsv
Write-Verbose "  IPv6 address   : $pipV6"
if ($AddPublicIpv4) {
    $pipV4 = az network public-ip show --name $pipV4Name -g $rgName --query ipAddress --output tsv
    Write-Verbose "  IPv4 address   : $pipV4"
}
Write-Verbose "Download the initial client bundle for a dev machine:"
Write-Verbose "  az keyvault secret show --vault-name $kvName --name $clientP12SecretName --query value -o tsv | base64 -d > strongswan-client-001.p12"
Write-Verbose "  az keyvault secret show --vault-name $kvName --name $clientP12PwdSecretName --query value -o tsv > strongswan-client-001.p12.pwd"
