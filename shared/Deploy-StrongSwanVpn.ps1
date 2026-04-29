#!/usr/bin/env pwsh

<# .SYNOPSIS
  Deploy an Ubuntu VM running strongSwan as an IKEv2 road-warrior VPN gateway.

.DESCRIPTION
  Creates, idempotently via Azure CLI:

    * Network Security Group `nsg-llm-gateway-dev-001`, Security group for gateway subnet.
    * Managed Identity `id-vmstrongdev001`, Identity for the VPN gateway server.
    * Public IP `pip-vmstrongdev001-australiaeast-01`, Public IPv6.
    * Public IP `pipv4-vmstrongdev001-australiaeast-01`, Public IPv4.
    * Network Interface `nic-vmstrongdev001-01`, Separate NIC, so that public IP can be retained if server is recreated.
    * Virtual Machine `vmstrongdev001`, StrongSwan virtual machine.
    * Disk `osdiskvmstrongdev001`, OS disk for the VM.
 
  Adds a subnet to the hub vnet:
     * `subnet-llm-gateway-dev-australiaeast-001`
     
  DNS names are:
    * "strongswan-<OrgId>-dev.australiaeast.cloudapp.azure.com"
    * "strongswan-<OrgId>-dev-ipv4.australiaeast.cloudapp.azure.com"

  Addresses are derived deterministically with an IPv6 ULA Global ID 10-hex-character
  SHA256 prefix of the subscription ID. IPv4 has a 10.x network using the first byte.
  
  This gives subscriptions unique but consistent ranges.

  Default machine size is 'Standard_D2s_v6'.

  Required secrets and certificates are stored in the shared Key Vault.

  The virtual machine is configured to shut down automatically (based on Brisbane, Australia time), to save costs.

  VPN address pools:
  * IPv6 allocates addresses from the range `--:300::1000` to `--:300::1fff`.
  * IPv4 allocates addresses from the range `--.48.128` to `--.48.255`.

.EXAMPLE

  az login
  az account set --subscription <subscription id>
  $VerbosePreference = 'Continue'
  $env:DEPLOY_VPN_USER_PASSWORD = 'P@ssword01'
  ./shared/Deploy-StrongSwanVpn.ps1
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
  ## Two character IPv6 Unique Local Address vnet ID to use for core subnet (default 01)
  [string]$VnetId = $ENV:DEPLOY_HUB_VNET_ID ?? ("01"),
  ## Two character IPv6 Unique Local Address subnet ID to use for gateway subnet (default 00)
  [string]$SubnetId = $ENV:DEPLOY_GATEWAY_SUBNET_ID ?? ("00"),
  ## Two character IPv6 Unique Local Address vnet ID to use for core subnet (default 03)
  [string]$PoolVnetId = $ENV:DEPLOY_POOL_VNET_ID ?? ("03"),
  ## Two character subnet id for VPN clients (default 00)
  [string]$PoolSubnetId = $ENV:DEPLOY_POOL_SUBNET_ID ?? '00',
  ## Path where generated material is written. Default: `<repo-root>/temp`.
  ## This path MUST be gitignored; the repo root already excludes `temp/`.
  [string]$TempPath = $ENV:DEPLOY_TEMP_PATH
)

<#
NOTE: Scripts do not use functions, so they can be run interactively.

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

# ---------------------------------------------------------
# Names

$rgName = "rg-$Purpose-core-$Instance".ToLowerInvariant()
$rg = az group show --name $rgName 2>$null | ConvertFrom-Json
$location = $rg.location

$appName = 'strongswan'

$vmName = "vm$appName$Instance".ToLowerInvariant()

$gatewayNsgName = "nsg-$Purpose-gateway-$Environment-001".ToLowerInvariant()
$identityName = "id-$vmName-$Environment".ToLowerInvariant()
$pipV6Name = "pip-$vmName-$Environment-$location-$Instance".ToLowerInvariant()
$pipV4Name = "pipv4-$vmName-$Environment-$location-$Instance".ToLowerInvariant()
$nicName = "nic-01-$vmName-$Environment-$Instance".ToLowerInvariant()
$vmOsDisk = "osdisk$vmName".ToLowerInvariant()

$gatewaySubnetName = "snet-$Purpose-gateway-$Environment-$location-001".ToLowerInvariant()

Write-Verbose "Network Security Group: $gatewayNsgName"
Write-Verbose "Managed Identity: $identityName"
Write-Verbose "Public IP: $pipV6Name"
Write-Verbose "Public IP: $pipV4Name"
Write-Verbose "Network Interface: $nicName"
Write-Verbose "Virtual Machine: $vmName"
Write-Verbose "OS Disk: $vmOsDisk"
Write-Verbose "Subnet: $gatewaySubnetName"

# ---------------------------------------------------------
# Other values

# Networking
$vnetName = "vnet-$Purpose-hub-$location-$Instance".ToLowerInvariant()

# Global will default to unique value per subscription
$prefixV6 = "fd$($UlaGlobalId.Substring(0, 2)):$($UlaGlobalId.Substring(2, 4)):$($UlaGlobalId.Substring(6, 4))"
$gatewaySubnetAddressV6 = [IPAddress]"$($prefixV6):$($VnetId)$($SubnetId)::"
$gatewaySubnetV6 = "$gatewaySubnetAddressV6/64"

# Azure only supports dual-stack (not single stack IPv6)
# "At least one IPv4 ipConfiguration is required for an IPv6 ipConfiguration on the network interface"

# Use the first byte of the ULA Global ID, and the vnet ID (as decimal)
$prefixByte = [int]"0x$($UlaGlobalId.Substring(0, 2))"
$decVnet = [int]("0x$VnetId" -bAnd 0xf) -shl 4
$decSubnet = [int]("0x$SubnetId" -bAnd 0xf)
$gatewaySubnetAddressV4 = [IPAddress]"10.$prefixByte.$($decVnet + $decSubnet).0"
$gatewaySubnetV4 = "$gatewaySubnetAddressV4/24"

# KV, to assign identity permissions
$kvName = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()

# Public DNS
$pipV6DnsName = "vpn-$OrgId-$Environment-$Instance".ToLowerInvariant()
$pipV4DnsName = "vpn-$OrgId-$Environment-$Instance-ipv4".ToLowerInvariant()

# Network interface details
$ipcV4Name = 'ipconfig1'  # Azure auto-creates this on the NIC; we update it.
$ipcV6Name = "ipc-v6-$vmName-$Environment-$Instance".ToLowerInvariant()

# Certificate secrets

$caCertSecretName = "$appName-$Environment-ca-cert".ToLowerInvariant()
$serverCertSecretName = "$appName-$Environment-server-cert".ToLowerInvariant()
$serverKeySecretName = "$appName-$Environment-server-key".ToLowerInvariant()

# VPN pools

$poolSubnetAddressV6 = [IPAddress]"$($prefixV6):$($PoolVnetId)$($PoolSubnetId)::"
$poolSubnetV6 = "$poolSubnetAddressV6/64"

# IPv6 pool: /116 at ::1000 inside the /64.
$poolBaseV6 = [IPAddress]"$($prefixV6):$($PoolVnetId)$($PoolSubnetId)::1000"
$vipPoolRangeV6 = "$poolBaseV6/116"

$poolDecVnet = [int]("0x$PoolVnetId" -bAnd 0xf) -shl 4
$poolDecSubnet = [int]("0x$PoolSubnetId" -bAnd 0xf)
$poolSubnetAddressV4 = [IPAddress]"10.$prefixByte.$($poolDecVnet + $poolDecSubnet).0"
$poolSubnetV4 = "$poolSubnetAddressV4/24"

# IPv4 pool /25 at .128
$poolBaseV4 = [IPAddress]"10.$prefixByte.$($poolDecVnet + $poolDecSubnet).128"
$vipPoolRangeV4 = "$poolBaseV4/25"

Write-Verbose "VPN subnets: IPv6=$poolSubnetV6, IPv4=$poolSubnetV4"
Write-Verbose "VPN pools  : IPv6=$vipPoolRangeV6, IPv4=$vipPoolRangeV4"

# Tag dictionary matching the gateway-subnet script's style.
$TagDictionary = [ordered]@{
  BusinessUnit       = $Purpose
  ApplicationName    = $appName
  DataClassification = 'Non-business'
  Criticality        = 'Low'
  Env                = $Environment
}
$tags = $TagDictionary.Keys | ForEach-Object { $key = $_; "$key=$($TagDictionary[$key])" }

# ---------------------------------------------------------
# Network Security Group

$gwNsg = az network nsg show --name $gatewayNsgName -g $rgName 2>$null | ConvertFrom-Json
if (-not $gwNsg) {
  Write-Verbose "Creating core network security group $gatewayNsgName"
  az network nsg create --name $gatewayNsgName -g $rgName -l $location --tags $tags

  Write-Verbose "Adding Network security group rule 'AllowSSH' for port 22 to $gatewayNsgName"
  az network nsg rule create --name AllowSSH `
    --nsg-name $gatewayNsgName `
    --priority 1000 `
    --resource-group $rgName `
    --access Allow `
    --source-address-prefixes "*" `
    --source-port-ranges "*" `
    --direction Inbound `
    --destination-port-ranges 22

  Write-Verbose "Adding Network security group rule 'AllowICMP' for ICMP to $gatewayNsgName"
  az network nsg rule create --name AllowICMPv4 `
    --nsg-name $gatewayNsgName `
    --priority 1001 `
    --resource-group $rgName `
    --access Allow `
    --source-address-prefixes "*" `
    --direction Inbound `
    --destination-port-ranges "*" `
    --protocol Icmp

  # Can't create ICMPv6 via API.
  # If you create a rule, then you can update it via the UI.

  # az network nsg rule create --name AllowICMPv6 `
  #                            --nsg-name $gatewayNsgName `
  #                            --priority 1002 `
  #                            --resource-group $rgName `
  #                            --access Allow `
  #                            --source-address-prefixes "*" `
  #                            --direction Inbound `
  #                            --destination-port-ranges "*" `
  #                            --protocol Icmp

  # Viewing the rule has Protocol = "ICMPv6"
  # az network nsg rule show --nsg-name $gatewayNsgName --resource-group $rgName -n "AllowICMPv6"    

  # $icmpv6 = @{
  #     properties = @{
  #         priority                 = 1002
  #         access                   = 'Allow'
  #         direction                = 'Inbound'
  #         protocol                 = 'ICMPv6'
  #     }
  # } | ConvertTo-Json -Depth 5
  # az rest `
  #   --method put `
  #   --url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.Network/networkSecurityGroups/$gatewayNsgName/securityRules/AllowICMPv6?api-version=2023-09-01" `
  #   --headers "Content-Type=application/json" `
  #   --body $icmpv6

  # But fails parsing the protocol
  # Bad Request({"error":{"code":"InvalidRequestContent","message":"The request content was invalid and could not be deserialized: 'Error parsing Infinity value. Path 'properties.protocol', line 4, position 15.'."}})
                            
  Write-Verbose "Adding Network security group rule 'AllowHTTP' for port 80, 443 to $gatewayNsgName"
  az network nsg rule create --name AllowHTTP `
    --nsg-name $gatewayNsgName `
    --priority 1003 `
    --resource-group $rgName `
    --access Allow `
    --source-address-prefixes "*" `
    --source-port-ranges "*" `
    --direction Inbound `
    --destination-port-ranges 80 443

  # Check rules
  # az network nsg rule list --nsg-name $nsgDmzName --resource-group $rgName
} else {
  Write-Verbose "Network Security Group already exists"
}

# ---------------------------------------------------------
# Subnet

$gwSnet = az network vnet subnet show --name $gatewaySubnetName -g $rgName --vnet-name $vnetName 2>$null | ConvertFrom-Json
if (-not $gwSnet) {
  Write-Verbose "Creating core subnet $gatewaySubnetName ($gatewaySubnetV6, $gatewaySubnetV4)"
  $gwSnet = az network vnet subnet create --name $gatewaySubnetName `
    --address-prefix $gatewaySubnetV6 $gatewaySubnetV4 `
    --resource-group $rgName `
    --vnet-name $vnetName `
    --network-security-group $gatewayNsgName | ConvertFrom-Json
} else {
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
    --resource-group $rgName `
    --object-id $principalId `
    --secret-permissions get list `
    --output none
  if ($LASTEXITCODE -ne 0) { throw "az keyvault set-policy failed for identity '$identityName' on '$kvName'" }
} else {
  Write-Verbose "Managed Identity already exists"
}
$uamiResourceId = $identity.id
$uamiClientId = $identity.clientId

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
} else {
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
  } else {
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
    --subnet $gwSnet.Id `
    --tags $tags
  if ($LASTEXITCODE -ne 0) { throw "az network nic create '$nicName' failed." }

  Write-Verbose "Adding NIC IP Config $ipcV6Name ($pipV6Name) to $nicName"
  az network nic ip-config create `
    --name $ipcV6Name `
    --nic-name $nicName  `
    --resource-group $rgName `
    --subnet $gwSnet.Id `
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
} else {
  Write-Verbose "Network interface already exists"
}

# ---------------------------------------------------------
# Custom network rules

$existingIke = az network nsg rule show --nsg-name $gatewayNsgName -g $rgName -n 'AllowIKE' 2>$null | ConvertFrom-Json
if (-not $existingIke) {
  Write-Verbose "Adding NSG rule IKE"
  az network nsg rule create --name 'AllowIKE' `
    --nsg-name $gatewayNsgName `
    --priority 2100 `
    --resource-group $rgName `
    --access Allow `
    --source-address-prefixes '*' `
    --source-port-ranges '*' `
    --direction Inbound `
    --protocol Udp `
    --destination-port-ranges 500 `
    --output none
  if ($LASTEXITCODE -ne 0) { throw "az network nsg rule create failed." }
}

$existingIPsec = az network nsg rule show --nsg-name $gatewayNsgName -g $rgName -n 'AllowIPsecNatT' 2>$null | ConvertFrom-Json
if (-not $existingIPsec) {
  Write-Verbose "Adding NSG rule IPsec"
  az network nsg rule create --name 'AllowIPsecNatT' `
    --nsg-name $gatewayNsgName `
    --priority 2101 `
    --resource-group $rgName `
    --access Allow `
    --source-address-prefixes '*' `
    --source-port-ranges '*' `
    --direction Inbound `
    --protocol Udp `
    --destination-port-ranges 4500 `
    --output none
  if ($LASTEXITCODE -ne 0) { throw "az network nsg rule create failed." }

  # Check rules
  # az network nsg rule list --nsg-name 'nsg-llm-gateway-dev-001' -g 'rg-llm-core-001'
}

# ---------------------------------------------------------
# Stored secrets in Key Vault

# Resolve $TempPath to an absolute path; default to repo-root `temp/`.
if (-not $TempPath) {
    # $PSScriptRoot is b-shared/; repo root is one level up.
    $TempPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'temp'
}
New-Item -ItemType Directory -Path $TempPath -Force | Out-Null
$TempPath = (Resolve-Path $TempPath).ProviderPath
Write-Verbose "Local material directory: $TempPath"

# Well-known file paths inside $TempPath.
$caKeyPath           = Join-Path $TempPath 'strongswan-ca.key'
$caPemPath           = Join-Path $TempPath 'strongswan-ca.pem'
$serverKeyPath       = Join-Path $TempPath 'strongswan-server.key'
$serverPemPath       = Join-Path $TempPath 'strongswan-server.pem'

# 1. CA for demo

$caCn = "strongSwan $OrgId $Environment CA"
if ((Test-Path $caKeyPath) -and (Test-Path $caPemPath)) {
    Write-Verbose "CA already present, skipping generation."
}
else {
    Write-Verbose "Generating CA private key (RSA 4096) -> $caKeyPath"
    $caKeyTmp = "$caKeyPath.partial"
    if (Test-Path $caKeyTmp) { Remove-Item $caKeyTmp -Force }
    # `pki --gen` writes the key to stdout when no --outform file is given.
    pki --gen --type rsa --size 4096 --outform pem > $caKeyTmp
    if ($LASTEXITCODE -ne 0) { throw "pki --gen failed with exit code $LASTEXITCODE" }
    Move-Item -Path $caKeyTmp -Destination $caKeyPath -Force

    Write-Verbose "Issuing self-signed CA cert (DN: CN=$caCn, 10-year lifetime) -> $caPemPath"
    $caPemTmp = "$caPemPath.partial"
    if (Test-Path $caPemTmp) { Remove-Item $caPemTmp -Force }
    # --lifetime is in days; 10 * 365 = 3650.
    Get-Content -Path $caKeyPath -Raw | pki --self --ca --lifetime 3650 --dn "CN=$caCn" --outform pem > $caPemTmp
    if ($LASTEXITCODE -ne 0) { throw "pki --self failed with exit code $LASTEXITCODE" }
    Move-Item -Path $caPemTmp -Destination $caPemPath -Force
}

# 2. Server keypair + cert signed by the CA (5-year lifetime).

if ((Test-Path $serverKeyPath) -and (Test-Path $serverPemPath)) {
    Write-Verbose "Server cert already present, skipping generation."
}
else {
    Write-Verbose "Generating server private key (RSA 4096) -> $serverKeyPath"
    $serverKeyTmp = "$serverKeyPath.partial"
    if (Test-Path $serverKeyTmp) { Remove-Item $serverKeyTmp -Force }
    pki --gen --type rsa --size 4096 --outform pem > $serverKeyTmp
    if ($LASTEXITCODE -ne 0) { throw "pki --gen (server) failed with exit code $LASTEXITCODE" }
    Move-Item -Path $serverKeyTmp -Destination $serverKeyPath -Force

    # SANs: one FQDN per entry, plus the serverAuth EKU flag.
    $serverCn = $fqdnV6
    $pkiIssueArgs = @(
        '--issue',
        '--cacert', $caPemPath,
        '--cakey',  $caKeyPath,
        '--dn',     "CN=$serverCn",
        '--lifetime', (5 * 365).ToString(),
        '--flag',   'serverAuth',
        '--outform','pem'
    )
    foreach ($fqdn in $fqdnList) {
        $pkiIssueArgs += @('--san', $fqdn)
    }
    Write-Verbose "Issuing server cert (DN: CN=$serverCn, SANs: $($fqdnList -join ', '), 5-year lifetime) -> $serverPemPath"
    $serverPemTmp = "$serverPemPath.partial"
    if (Test-Path $serverPemTmp) { Remove-Item $serverPemTmp -Force }
    # Materialise the public key to a small temp file, in PEM so the file can be read as text.
    $serverPubTmp = Join-Path $TempPath 'strongswan-server.pub.partial'
    if (Test-Path $serverPubTmp) { Remove-Item $serverPubTmp -Force }
    pki --pub --in $serverKeyPath --outform pem > $serverPubTmp
    if ($LASTEXITCODE -ne 0) { throw "pki --pub (server) failed with exit code $LASTEXITCODE" }
    try {
        pki @pkiIssueArgs --in $serverPubTmp > $serverPemTmp
        if ($LASTEXITCODE -ne 0) { throw "pki --issue (server) failed with exit code $LASTEXITCODE" }
    }
    finally {
        if (Test-Path $serverPubTmp) { Remove-Item $serverPubTmp -Force }
    }
    Move-Item -Path $serverPemTmp -Destination $serverPemPath -Force
}

# 3. Upload the files to the Key Vault

$existingCaCert = az keyvault secret show --vault-name $kvName --name $caCertSecretName 2>$null | ConvertFrom-Json
if (-not $existingCaCert) {
  Write-Verbose "Uploading Key Vault CA Cert secret"
  az keyvault secret set --vaultName $kvName --name $caCertSecretName --file $caPemPath --content-type 'application/x-pem-file'
  if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed" }
}

$existingServerCert = az keyvault secret show --vault-name $kvName --name $serverCertSecretName 2>$null | ConvertFrom-Json
if (-not $existingServerCert) {
  Write-Verbose "Uploading Key Vault Server Cert secret"
  az keyvault secret set --vaultName $kvName --name $serverCertSecretName --file $serverPemPath --content-type 'application/x-pem-file'
  if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed" }
}

$existingServerKey = az keyvault secret show --vault-name $kvName --name $serverKeySecretName 2>$null | ConvertFrom-Json
if (-not $existingServerKey) {
  Write-Verbose "Uploading Key Vault Server Key secret"
  az keyvault secret set --vaultName $kvName --name $serverKeySecretName --file $serverKeyPath --content-type 'application/x-pem-file'
  if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed" }
}

# ---------------------------------------------------------
# Virtual Machine

$vm = az vm show --name $vmName -g $rgName 2>$null | ConvertFrom-Json
if (-not $vm) {

  # Render cloud-init.

  $tempDir = Join-Path $PSScriptRoot 'temp'
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
  $tempDir = (Resolve-Path $tempDir).ProviderPath
  $templatePath = Join-Path $PSScriptRoot 'data' 'strongswan-cloud-init.txt'
  $renderedPath = Join-Path $tempDir 'strongswan-cloud-init.txt~'

  Write-Verbose "Rendering cloud-init from '$templatePath' -> '$renderedPath'"
  # Use literal string .Replace() (not PS -replace) so regex metacharacters in
  # the password (e.g. '$') pass through unchanged.
  $rendered = (Get-Content -Path $templatePath -Raw)
  $subs = [ordered]@{
    '#INIT_VPN_USERNAME#'            = $VpnUsername
    '#INIT_VPN_PASSWORD#'            = $VpnUserPassword
    '#INIT_VPN_SUBNET_IPV6#'         = $poolSubnetV6
    '#INIT_VPN_SUBNET_IPV4#'         = $poolSubnetV4
    '#INIT_VIP_POOL_IPV6#'           = $vipPoolRangeV6
    '#INIT_VIP_POOL_IPV4#'           = $vipPoolRangeV4
    '#INIT_SERVER_FQDNS#'            = $fqdnJoinedList
    '#INIT_KEY_VAULT_NAME#'          = $kvName
    '#INIT_CA_SECRET_NAME#'          = $caCertSecretName
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
}
else {
  Write-Verbose "VM '$vmName' already present, skipping create."
}

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
Write-Verbose "cloud-init reported 'done'."

# Summary output.
Write-Verbose "strongSwan VPN VM deployed:"
Write-Verbose "  VM name        : $vmName"
Write-Verbose "  IPv6 FQDN      : $fqdnV6"
if ($AddPublicIpv4) {
  Write-Verbose "  IPv4 FQDN      : $fqdnV4"
}
$pipV6 = az network public-ip show --name $pipV6Name -g $rgName --query ipAddress --output tsv
Write-Verbose "  IPv6 address   : $pipV6"
if ($AddPublicIpv4) {
  $pipV4 = az network public-ip show --name $pipV4Name -g $rgName --query ipAddress --output tsv
  Write-Verbose "  IPv4 address   : $pipV4"
}
