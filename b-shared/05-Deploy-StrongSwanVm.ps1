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
    * One Ubuntu LTS VM with a system-assigned managed identity and a
      rendered cloud-init payload from `data/strongswan-cloud-init.txt`.
    * A `Key Vault Secrets User` RBAC role assignment on the shared Key Vault
      so the VM can fetch its cert material via its managed identity.
    * An optional auto-shutdown schedule.

  The rendered cloud-init file pulls the CA cert, server cert, and server
  private key from Key Vault at first boot and brings up the strongSwan
  service with one road-warrior connection accepting both EAP-MSCHAPv2 and
  client-certificate auth.

.NOTES
  PREREQUISITES
  * `01-Deploy-AzureMonitor.ps1`, `02-Deploy-KeyVault.ps1`, and
    `03-Deploy-GatewaySubnet.ps1` must have run for this environment.
  * `04-Deploy-Certificate.ps1` must have run; this script fails early if the
    CA/server/server-key secrets are missing in Key Vault.

  PAIRS WITH 04-Deploy-Certificate.ps1
  The server cert SANs are issued by `04` from the same deterministic FQDN
  formulas. `-OrgId`, `-Environment`, `-Location` (via RG), and
  `-AddPublicIpv4` MUST match the values used when `04` ran. Exporting the
  matching `DEPLOY_*` env vars once and running both scripts in the same
  shell is the recommended workflow.

      IPv6 FQDN = "strongswan-<OrgId>-<Environment>.<Location>.cloudapp.azure.com"
      IPv4 FQDN = "strongswan-<OrgId>-<Environment>-ipv4.<Location>.cloudapp.azure.com"

  `<Location>` is derived here from the core RG's location; `04` takes it as
  an explicit parameter with `australiaeast` as the default.

  VPN CLIENT POOL ADDRESSING
  The VPN client IP pool is a pure strongSwan construct (no Azure VNet /
  subnet is created for it). Addresses are derived deterministically from
  `-UlaGlobalId` (the same hash used by `03-Deploy-GatewaySubnet.ps1`) and
  `-VpnVnetId` (default `02`). For a ULA Global ID decomposed as
  `gg gggg gggggg`:

      IPv4 subnet  = 10.<gg-dec>.<VpnVnetId-dec>.0/24
      IPv4 pool    = upper /25 of the subnet (e.g. 10.171.2.128/25)
      IPv6 subnet  = fd<gg>:<gggg>:<gggggg>:<VpnVnetId>00::/64
      IPv6 pool    = ::1000/116 inside the subnet (4096 addresses)

  EAP PASSWORD
  `-VpnUserPassword` (env `DEPLOY_VPN_USER_PASSWORD`) is required. It is NOT
  stored in Key Vault in this MVP; it is baked into `/etc/swanctl/conf.d/
  secrets.conf` on the VM (root-read-only). Treat shell history accordingly.

  CONVENTIONS
  Follows the Azure CAF naming and tagging conventions used elsewhere in this
  repo, and the project script conventions in `AGENTS.md`.

.EXAMPLE

  az login
  az account set --subscription <subscription id>
  $VerbosePreference = 'Continue'
  $env:DEPLOY_VPN_USER_PASSWORD = 'replace-me'
  ./b-shared/05-Deploy-StrongSwanVm.ps1
#>
[CmdletBinding()]
param (
    ## Purpose prefix (matches `02-Deploy-KeyVault.ps1` / `03-Deploy-GatewaySubnet.ps1`).
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
    [string]$AdminUsername = $ENV:DEPLOY_ADMIN_USERNAME ?? 'admin',
    ## EAP-MSCHAPv2 username seeded into swanctl secrets.
    [string]$VpnUsername = $ENV:DEPLOY_VPN_USERNAME ?? 'vpnuser',
    ## EAP-MSCHAPv2 password (REQUIRED).
    [string]$VpnUserPassword = $ENV:DEPLOY_VPN_USER_PASSWORD,
    ## Two-character VPN vnet id (addressing slot, not an Azure VNet).
    [string]$VpnVnetId = $ENV:DEPLOY_VPN_VNET_ID ?? '02',
    ## Ten-character IPv6 ULA Global ID (MUST match `03-Deploy-GatewaySubnet.ps1`).
    [string]$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10),
    ## Public-IP DNS label stem (IPv6 uses this as-is; IPv4 appends "-ipv4"). Must match `04`.
    [string]$ServerDnsLabel = $ENV:DEPLOY_VPN_DNS_LABEL,
    ## Auto-shutdown time in UTC, default 0900 = 19:00 in Brisbane. Empty string disables.
    [string]$ShutdownUtc = $ENV:DEPLOY_SHUTDOWN_UTC ?? '0900',
    ## Email to send auto-shutdown notification to (optional).
    [string]$ShutdownEmail = $ENV:DEPLOY_SHUTDOWN_EMAIL ?? '',
    ## Add a public IPv4 in addition to the IPv6. MUST match the `04` run.
    [switch]$AddPublicIpv4 = ([string]::IsNullOrEmpty($ENV:DEPLOY_ADD_IPV4) -or $ENV:DEPLOY_ADD_IPV4 -eq 'true' -or $ENV:DEPLOY_ADD_IPV4 -eq '1')
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))"
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
$VmSize = $ENV:DEPLOY_VM_SIZE ?? 'Standard_D2s_v6'
$AdminUsername = $ENV:DEPLOY_ADMIN_USERNAME ?? 'admin'
$VpnUsername = $ENV:DEPLOY_VPN_USERNAME ?? 'vpnuser'
$VpnUserPassword = $ENV:DEPLOY_VPN_USER_PASSWORD
$VpnVnetId = $ENV:DEPLOY_VPN_VNET_ID ?? '02'
$UlaGlobalId = $ENV:DEPLOY_GLOBAL_ID ?? (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((az account show --query id --output tsv))))).Hash.Substring(0, 10)
$ServerDnsLabel = $ENV:DEPLOY_VPN_DNS_LABEL
$ShutdownUtc = '0900'
$ShutdownEmail = ''
$AddPublicIpv4 = $true
#>

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($VpnUserPassword)) {
    throw 'You must supply a value for -VpnUserPassword or set environment variable DEPLOY_VPN_USER_PASSWORD.'
}

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Deploying strongSwan VM for environment '$Environment' in subscription '$SubscriptionId'$($AddPublicIpv4 ? ' with IPv4' : '')"

# ---------------------------------------------------------------------------
# Resolve the shared RG, VNet, gateway subnet, gateway NSG, Key Vault.
# We READ all of these; we never create them.
# ---------------------------------------------------------------------------

$rgName            = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$rg                = az group show --name $rgName 2>$null | ConvertFrom-Json
if (-not $rg) { throw "Resource group '$rgName' not found. Run a-infrastructure scripts first." }
$location          = $rg.location
$locationLower     = $location.ToLowerInvariant()

$vnetName          = "vnet-$Purpose-hub-$location-$Instance".ToLowerInvariant()
$gatewayNsgName    = "nsg-$Purpose-gateway-$Environment-001".ToLowerInvariant()
$gatewaySubnetName = "snet-$Purpose-gateway-$Environment-$location-001".ToLowerInvariant()

$vnet    = az network vnet show --name $vnetName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $vnet) { throw "VNet '$vnetName' not found. Run `a-infrastructure/01-*.ps1` first." }

$gwSnet  = az network vnet subnet show --name $gatewaySubnetName -g $rgName --vnet-name $vnetName 2>$null | ConvertFrom-Json
if (-not $gwSnet) { throw "Gateway subnet '$gatewaySubnetName' not found. Run `b-shared/03-Deploy-GatewaySubnet.ps1` first." }

$gwNsg   = az network nsg show --name $gatewayNsgName -g $rgName 2>$null | ConvertFrom-Json
if (-not $gwNsg) { throw "Gateway NSG '$gatewayNsgName' not found. Run `b-shared/03-Deploy-GatewaySubnet.ps1` first." }

$kvName  = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()
$kv      = az keyvault show --name $kvName 2>$null | ConvertFrom-Json
if (-not $kv) { throw "Key Vault '$kvName' not found. Run `b-shared/02-Deploy-KeyVault.ps1` first." }
$kvResourceId = $kv.id
Write-Verbose "Resolved shared resources: RG=$rgName, VNet=$vnetName, Subnet=$gatewaySubnetName, NSG=$gatewayNsgName, KV=$kvName"

# ---------------------------------------------------------------------------
# Derived names and addressing.
# ---------------------------------------------------------------------------

$appName   = 'strongswan'
$vmName    = "vm$appName$Instance".ToLowerInvariant()
$vmOsDisk  = "osdiskvm$appName$Instance".ToLowerInvariant()
$nicName   = "nic-01-$vmName-$Environment-$Instance".ToLowerInvariant()
$ipcV4Name = 'ipconfig1'  # Azure auto-creates this on the NIC; we update it.
$ipcV6Name = "ipc-v6-$vmName-$Environment-$Instance".ToLowerInvariant()
$pipV6Name = "pip-$vmName-$Environment-$location-$Instance".ToLowerInvariant()
$pipV4Name = "pipv4-$vmName-$Environment-$location-$Instance".ToLowerInvariant()

if (-not $ServerDnsLabel) {
    $ServerDnsLabel = "strongswan-$OrgId-$Environment".ToLowerInvariant()
}
$pipV6DnsLabel = $ServerDnsLabel.ToLowerInvariant()
$pipV4DnsLabel = "$ServerDnsLabel-ipv4".ToLowerInvariant()

# --- Reusable snippet: derive IPv6 / IPv4 PIP FQDNs from parameters ---------
# NOTE: Duplicated in `04-Deploy-Certificate.ps1`; keep the two copies in
# sync. See AGENTS.md on "do not extract to a module".
$ipv6Fqdn = "$pipV6DnsLabel.$locationLower.cloudapp.azure.com"
$ipv4Fqdn = "$pipV4DnsLabel.$locationLower.cloudapp.azure.com"
$fqdnList = @($ipv6Fqdn)
if ($AddPublicIpv4) { $fqdnList += $ipv4Fqdn }
Write-Verbose "Server FQDNs: $($fqdnList -join ', ')"
# ---------------------------------------------------------------------------

# --- Reusable snippet: VPN client pool addressing ---------------------------
# NOTE: This snippet is the canonical source for the pool derivation; the
# substituted values flow into cloud-init. See D5 in design.md and the
# vpn-gateway spec's "VPN client virtual IP pool" requirement.
#
# UlaGlobalId = gg gggg gggggg (10 hex chars). VpnVnetId is 2 hex chars.
$ulaGg       = $UlaGlobalId.Substring(0, 2)          # first byte, hex
$ulaGgggg    = $UlaGlobalId.Substring(2, 4)          # next 4 hex
$ulaTail     = $UlaGlobalId.Substring(6, 4)          # last 4 hex
$ulaGgDec    = [int]"0x$ulaGg"
$vpnVnetDec  = [int]"0x$VpnVnetId"

# IPv4: 10.<ggDec>.<vpnVnetDec>.0/24 ; pool = upper half /25 at .128.
$vpnSubnetIPv4 = "10.$ulaGgDec.$vpnVnetDec.0/24"
$vipPoolIPv4   = "10.$ulaGgDec.$vpnVnetDec.128/25"

# IPv6 subnet: fd<gg>:<gggg>:<gggggg>:<VpnVnetId>00::/64
$ipv6Prefix    = "fd$($ulaGg):$($ulaGgggg):$($ulaTail):$($VpnVnetId)00"
$vpnSubnetIPv6 = "$ipv6Prefix" + '::/64'
# IPv6 pool: /116 at ::1000 inside the /64.
$vipPoolIPv6   = "$ipv6Prefix" + '::1000/116'
Write-Verbose "VPN subnets: IPv4=$vpnSubnetIPv4, IPv6=$vpnSubnetIPv6"
Write-Verbose "VPN pools  : IPv4=$vipPoolIPv4, IPv6=$vipPoolIPv6"
# ---------------------------------------------------------------------------

# Secret names must match those written by `04-Deploy-Certificate.ps1`.
$envLower              = $Environment.ToLowerInvariant()
$secretPrefix          = "strongswan-$envLower"
$caSecretName          = "$secretPrefix-ca-cert"
$serverCertSecretName  = "$secretPrefix-server-cert"
$serverKeySecretName   = "$secretPrefix-server-key"
$clientP12SecretName   = "$secretPrefix-client-001-p12"
$clientP12PwdSecretName= "$secretPrefix-client-001-p12-password"

Write-Verbose "Verifying Key Vault secrets from 04-Deploy-Certificate.ps1 ..."
foreach ($name in @($caSecretName, $serverCertSecretName, $serverKeySecretName)) {
    $s = az keyvault secret show --vault-name $kvName --name $name 2>$null | ConvertFrom-Json
    if (-not ($s -and $s.value)) {
        throw "Key Vault secret '$name' is missing in '$kvName'. Run `b-shared/04-Deploy-Certificate.ps1` first."
    }
    Write-Verbose "  OK: $name"
}

# ---------------------------------------------------------------------------
# Tag dictionary matching 03-Deploy-GatewaySubnet.ps1's style.
# ---------------------------------------------------------------------------

$TagDictionary = [ordered]@{
    DataClassification = 'Non-business'
    Criticality        = 'Low'
    BusinessUnit       = $Purpose
    ApplicationName    = $appName
    Env                = $Environment
}
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

# ---------------------------------------------------------------------------
# 10. NSG rules: AllowIKE (2100, UDP 500), AllowIPsecNatT (2101, UDP 4500).
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# 11. Public IPs + NIC (idempotent).
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# 12. Render cloud-init.
# ---------------------------------------------------------------------------

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
    '#INIT_VPN_SUBNET_IPV4#'         = $vpnSubnetIPv4
    '#INIT_VPN_SUBNET_IPV6#'         = $vpnSubnetIPv6
    '#INIT_VIP_POOL_IPV4#'           = $vipPoolIPv4
    '#INIT_VIP_POOL_IPV6#'           = $vipPoolIPv6
    '#INIT_SERVER_FQDNS#'            = $serverFqdnsJoined
    '#INIT_KEY_VAULT_NAME#'          = $kvName
    '#INIT_CA_SECRET_NAME#'          = $caSecretName
    '#INIT_SERVER_CERT_SECRET_NAME#' = $serverCertSecretName
    '#INIT_SERVER_KEY_SECRET_NAME#'  = $serverKeySecretName
    '#INIT_ADMIN_USER#'              = $AdminUsername
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

# ---------------------------------------------------------------------------
# 13. VM create + managed-identity RBAC + auto-shutdown.
# ---------------------------------------------------------------------------

$vm = az vm show --name $vmName -g $rgName 2>$null | ConvertFrom-Json
if (-not $vm) {
    Write-Verbose "Creating VM '$vmName' (size $VmSize, image UbuntuLTS, managed identity)"
    az vm create `
        --resource-group $rgName `
        --name $vmName `
        --location $location `
        --size $VmSize `
        --image UbuntuLTS `
        --os-disk-name $vmOsDisk `
        --admin-username $AdminUsername `
        --generate-ssh-keys `
        --nics $nicName `
        --assign-identity `
        --custom-data $renderedPath `
        --tags $tags `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az vm create '$vmName' failed." }
} else {
    Write-Verbose "VM '$vmName' already present, skipping create."
    # Ensure managed identity exists (no-op if already assigned).
    az vm identity assign --name $vmName --resource-group $rgName --output none
    if ($LASTEXITCODE -ne 0) { throw "az vm identity assign failed." }
}

$miPrincipalId = az vm identity show --name $vmName --resource-group $rgName --query principalId --output tsv
if (-not $miPrincipalId) { throw "Could not read managed identity principalId for '$vmName'." }
Write-Verbose "VM managed identity principal id: $miPrincipalId"

# RBAC: Key Vault Secrets User on the shared Key Vault (idempotent).
$existingRole = az role assignment list `
    --assignee-object-id $miPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role 'Key Vault Secrets User' `
    --scope $kvResourceId `
    --output json | ConvertFrom-Json
if ($existingRole -and $existingRole.Count -gt 0) {
    Write-Verbose "Role assignment 'Key Vault Secrets User' already present for VM managed identity."
} else {
    Write-Verbose "Granting 'Key Vault Secrets User' on '$kvName' to VM managed identity."
    az role assignment create `
        --role 'Key Vault Secrets User' `
        --assignee-object-id $miPrincipalId `
        --assignee-principal-type ServicePrincipal `
        --scope $kvResourceId `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "az role assignment create failed." }
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

# ---------------------------------------------------------------------------
# 14. Post-deploy verification + operator output.
# ---------------------------------------------------------------------------

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
$ciStdout = ($ciParsed.value | Where-Object { $_.code -eq 'ComponentStatus/StdOut/succeeded' } | Select-Object -First 1).message
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
Write-Output ""
Write-Output "strongSwan VPN VM deployed:"
Write-Output "  VM name        : $vmName"
Write-Output "  IPv6 FQDN      : $ipv6Fqdn"
if ($AddPublicIpv4) {
    Write-Output "  IPv4 FQDN      : $ipv4Fqdn"
}
$pipV6 = az network public-ip show --name $pipV6Name -g $rgName --query ipAddress --output tsv
Write-Output "  IPv6 address   : $pipV6"
if ($AddPublicIpv4) {
    $pipV4 = az network public-ip show --name $pipV4Name -g $rgName --query ipAddress --output tsv
    Write-Output "  IPv4 address   : $pipV4"
}
Write-Output "  Key Vault      : $kvName"
Write-Output "  Secrets        :"
Write-Output "    CA cert                 : $caSecretName"
Write-Output "    Server cert             : $serverCertSecretName"
Write-Output "    Server key              : $serverKeySecretName"
Write-Output "    Client 001 PKCS#12      : $clientP12SecretName (base64)"
Write-Output "    Client 001 P12 password : $clientP12PwdSecretName"
Write-Output ""
Write-Output "Download the initial client bundle for a dev machine:"
Write-Output "  az keyvault secret show --vault-name $kvName --name $clientP12SecretName --query value -o tsv | base64 -d > strongswan-client-001.p12"
Write-Output "  az keyvault secret show --vault-name $kvName --name $clientP12PwdSecretName --query value -o tsv > strongswan-client-001.p12.pwd"
Write-Output ""
Write-Output "Deployment complete."
