#!/usr/bin/env pwsh

<# .SYNOPSIS
  Generate strongSwan VPN certificate material locally and publish it to the shared Key Vault.

.DESCRIPTION
  Creates strongSwan certificate files and adds them to the shared KeyVault for:

    * "strongswan-<OrgId>-dev.australiaeast.cloudapp.azure.com"
    * "strongswan-<OrgId>-dev-ipv4.australiaeast.cloudapp.azure.com"
  
  Generation and upload are independently idempotent: each step checks for
  existing output (on disk or in Key Vault) and is skipped if present. A forced
  regeneration requires the operator to delete the relevant files in `./temp/`
  (and, optionally, purge the Key Vault secret).

.NOTES
  The generated files are created in the local `./temp/` directory (excluded from git):
    * CA keypair              -- strongswan-ca.key / strongswan-ca.pem      (RSA 4096, 10yr)
    * Server keypair + cert   -- strongswan-server.key / .pem                (RSA 4096, 5yr)
    * Initial client bundle   -- strongswan-client-001.key / .pem / .p12    (RSA 4096, 1yr)
    * PKCS#12 password        -- strongswan-client-001-p12-password.txt

  The CA *private* key (strongswan-ca.key) is not uploaded. It stays only in
  `./temp/` on the operator machine, so only whoever ran this script can issue
  new client certs.
  
  Generation and upload are independently idempotent: each step checks for
  existing output (on disk or in Key Vault) and is skipped if present. A forced
  regeneration requires the operator to delete the relevant files in `./temp/`
  (and, optionally, purge the Key Vault secret).

  CONVENTIONS
  Follows the Azure CAF naming and tagging conventions used elsewhere in this
  repo, and the project script conventions in `AGENTS.md`.

.EXAMPLE

  az login
  az account set --subscription <subscription id>
  $VerbosePreference = 'Continue'
  ./b-shared/05-Deploy-Certificate.ps1
#>
[CmdletBinding()]
param (
    ## Purpose prefix (matches the Key Vault deployment script).
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Deployment environment, e.g. Prod, Dev, QA, Stage, Test.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## Identifier for the organisation (or subscription) to make global names unique.
    [string]$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
    ## Instance number uniquifier for the Key Vault (matches the Key Vault deployment script).
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001',
    ## Public-IP DNS label stem (IPv6 uses this as-is; IPv4 appends "-ipv4").
    [string]$ServerDnsLabel = $ENV:DEPLOY_VPN_DNS_LABEL,
    ## Path where generated material is written. Default: `<repo-root>/temp`.
    ## This path MUST be gitignored; the repo root already excludes `temp/`.
    [string]$TempPath = $ENV:DEPLOY_TEMP_PATH
)

<#
To run interactively, start with:

$VerbosePreference = 'Continue'

$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM'
$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev'
$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))"
$Location = $ENV:DEPLOY_LOCATION ?? 'australiaeast'
$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
$TempPath = $ENV:DEPLOY_TEMP_PATH
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SubscriptionId = $(az account show --query id --output tsv)
Write-Verbose "Generating strongSwan cert material for environment '$Environment' in subscription '$SubscriptionId'"

# ---------------------------------------------------------------------------
# Derived names and paths
# ---------------------------------------------------------------------------

# Key Vault name: must match the Key Vault deployment script.
$kvName = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()

Write-Verbose "Looking up Key Vault $kvName"
$kv = az keyvault show --name $kvName 2>$null | ConvertFrom-Json
if (-not $kv) {
    throw "Key Vault '$kvName' not found. Run the Key Vault deployment script first (ensure matching -Purpose/-Environment/-OrgId/-Instance)."
}

# Secret-name prefix: `strongswan-<env>-` (lowercase).
$secretPrefix = "strongswan-$($Environment.ToLowerInvariant())"
Write-Verbose "Key Vault secret prefix: $secretPrefix-*"

# DNS label stem defaults to `strongswan-<OrgId>-<Environment>`.
$serverDnsLabel = "strongswan-$OrgId-$Environment".ToLowerInvariant()

# Derive IPv6 / IPv4 PIP FQDNs from parameters
$locationLower = $kv.location.ToLowerInvariant()
$ipv6Fqdn = "$serverDnsLabel.$locationLower.cloudapp.azure.com".ToLowerInvariant()
$ipv4Fqdn = "$serverDnsLabel-ipv4.$locationLower.cloudapp.azure.com".ToLowerInvariant()
$fqdnList = @($ipv6Fqdn)
$fqdnList += $ipv4Fqdn
Write-Verbose "Server cert SAN FQDNs: $($fqdnList -join ', ')"
# ---------------------------------------------------------------------------

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
$clientId            = '001'
$clientKeyPath       = Join-Path $TempPath "strongswan-client-$clientId.key"
$clientPemPath       = Join-Path $TempPath "strongswan-client-$clientId.pem"
$clientP12Path       = Join-Path $TempPath "strongswan-client-$clientId.p12"
$clientP12PwdPath    = Join-Path $TempPath "strongswan-client-$clientId-p12-password.txt"

# ---------------------------------------------------------------------------
# 1. CA keypair + self-signed cert (10-year lifetime).
# ---------------------------------------------------------------------------

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

# Verify: print CA cert, require CN match.
$caPrint = (pki --print --in $caPemPath) -join "`n"
Write-Verbose "CA cert print:`n$caPrint"
if ($caPrint -notmatch [regex]::Escape($caCn)) {
    throw "CA cert verification failed: expected CN '$caCn' not found in `pki --print` output."
}

# ---------------------------------------------------------------------------
# 2. Server keypair + cert signed by the CA (5-year lifetime).
# ---------------------------------------------------------------------------

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
    $serverCn = $ipv6Fqdn
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

# Verify: print server cert, require every expected SAN to appear.
$serverPrint = (pki --print --in $serverPemPath) -join "`n"
Write-Verbose "Server cert print:`n$serverPrint"
foreach ($fqdn in $fqdnList) {
    if ($serverPrint -notmatch [regex]::Escape($fqdn)) {
        throw "Server cert verification failed: expected SAN '$fqdn' not found in `pki --print` output."
    }
}

# ---------------------------------------------------------------------------
# 3. Initial client (001) keypair + cert + PKCS#12 bundle (1-year lifetime).
# ---------------------------------------------------------------------------

$clientCn = "client-$OrgId-$Environment-$clientId".ToLowerInvariant()

$allClientFilesPresent = (Test-Path $clientKeyPath) -and (Test-Path $clientPemPath) `
    -and (Test-Path $clientP12Path) -and (Test-Path $clientP12PwdPath)
if ($allClientFilesPresent) {
    Write-Verbose "Client 001 bundle already present, skipping generation."
}
else {
    # Password first; persist so re-runs don't change it.
    if (-not (Test-Path $clientP12PwdPath)) {
        Write-Verbose "Generating PKCS#12 password -> $clientP12PwdPath"
        $pwd = openssl rand -base64 24
        if ($LASTEXITCODE -ne 0) { throw "openssl rand failed with exit code $LASTEXITCODE" }
        # Trim newline; write as UTF8 with no BOM. Lock down where the FS supports it.
        [System.IO.File]::WriteAllText($clientP12PwdPath, ($pwd.Trim()))
        try { & chmod 600 $clientP12PwdPath 2>$null } catch { }
    }

    if (-not (Test-Path $clientKeyPath)) {
        Write-Verbose "Generating client private key (RSA 4096) -> $clientKeyPath"
        $clientKeyTmp = "$clientKeyPath.partial"
        if (Test-Path $clientKeyTmp) { Remove-Item $clientKeyTmp -Force }
        pki --gen --type rsa --size 4096 --outform pem > $clientKeyTmp
        if ($LASTEXITCODE -ne 0) { throw "pki --gen (client) failed with exit code $LASTEXITCODE" }
        Move-Item -Path $clientKeyTmp -Destination $clientKeyPath -Force
    }

    if (-not (Test-Path $clientPemPath)) {
        Write-Verbose "Issuing client cert (DN: CN=$clientCn, clientAuth EKU, 1-year lifetime) -> $clientPemPath"
        $clientPemTmp = "$clientPemPath.partial"
        if (Test-Path $clientPemTmp) { Remove-Item $clientPemTmp -Force }
        # Same rationale as the server block: materialise the public key as PEM
        # text to a temp file rather than piping binary DER through PowerShell.
        $clientPubTmp = Join-Path $TempPath "strongswan-client-$clientId.pub.partial"
        if (Test-Path $clientPubTmp) { Remove-Item $clientPubTmp -Force }
        pki --pub --in $clientKeyPath --outform pem > $clientPubTmp
        if ($LASTEXITCODE -ne 0) { throw "pki --pub (client) failed with exit code $LASTEXITCODE" }
        try {
            pki --issue `
                --cacert $caPemPath `
                --cakey  $caKeyPath `
                --dn "CN=$clientCn" `
                --lifetime (365).ToString() `
                --flag clientAuth `
                --outform pem `
                --in $clientPubTmp > $clientPemTmp
            if ($LASTEXITCODE -ne 0) { throw "pki --issue (client) failed with exit code $LASTEXITCODE" }
        }
        finally {
            if (Test-Path $clientPubTmp) { Remove-Item $clientPubTmp -Force }
        }
        Move-Item -Path $clientPemTmp -Destination $clientPemPath -Force
    }

    if (-not (Test-Path $clientP12Path)) {
        Write-Verbose "Packaging PKCS#12 bundle -> $clientP12Path"
        $clientP12Tmp = "$clientP12Path.partial"
        if (Test-Path $clientP12Tmp) { Remove-Item $clientP12Tmp -Force }
        # Use file: to pass the password without exposing it on the command line.
        openssl pkcs12 -export `
            -inkey $clientKeyPath `
            -in $clientPemPath `
            -certfile $caPemPath `
            -name $clientCn `
            -out $clientP12Tmp `
            -passout "file:$clientP12PwdPath"
        if ($LASTEXITCODE -ne 0) { throw "openssl pkcs12 -export failed with exit code $LASTEXITCODE" }
        Move-Item -Path $clientP12Tmp -Destination $clientP12Path -Force
    }
}

# ---------------------------------------------------------------------------
# 4. Key Vault upload (idempotent).
# ---------------------------------------------------------------------------

# Helper: upload a file as a Key Vault secret iff the name has no current value.
function Set-KvSecretIfAbsent {
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$ContentType
    )
    $existing = az keyvault secret show --vault-name $VaultName --name $Name 2>$null | ConvertFrom-Json
    if ($existing -and $existing.value) {
        Write-Verbose "Skipping Key Vault secret '$Name' (already present)."
        return
    }
    Write-Verbose "Uploading Key Vault secret '$Name' from $FilePath"
    $args = @('keyvault','secret','set','--vault-name',$VaultName,'--name',$Name,'--file',$FilePath)
    if ($ContentType) { $args += @('--content-type',$ContentType) }
    az @args --output none
    if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed for '$Name'" }
}

function Set-KvSecretValueIfAbsent {
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [string]$ContentType
    )
    $existing = az keyvault secret show --vault-name $VaultName --name $Name 2>$null | ConvertFrom-Json
    if ($existing -and $existing.value) {
        Write-Verbose "Skipping Key Vault secret '$Name' (already present)."
        return
    }
    Write-Verbose "Uploading Key Vault secret '$Name' (inline value, length $($Value.Length))"
    $args = @('keyvault','secret','set','--vault-name',$VaultName,'--name',$Name,'--value',$Value)
    if ($ContentType) { $args += @('--content-type',$ContentType) }
    az @args --output none
    if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed for '$Name'" }
}

$caCertSecretName         = "$secretPrefix-ca-cert"
$serverCertSecretName     = "$secretPrefix-server-cert"
$serverKeySecretName      = "$secretPrefix-server-key"
$clientP12SecretName      = "$secretPrefix-client-$clientId-p12"
$clientP12PwdSecretName   = "$secretPrefix-client-$clientId-p12-password"

Set-KvSecretIfAbsent -VaultName $kvName -Name $caCertSecretName       -FilePath $caPemPath       -ContentType 'application/x-pem-file'
Set-KvSecretIfAbsent -VaultName $kvName -Name $serverCertSecretName   -FilePath $serverPemPath   -ContentType 'application/x-pem-file'
Set-KvSecretIfAbsent -VaultName $kvName -Name $serverKeySecretName    -FilePath $serverKeyPath   -ContentType 'application/x-pem-file'

# PKCS#12 is binary. `az keyvault secret set --file` expects UTF-8 text; encode
# the .p12 as base64 and upload via --value so retrieval on the VM (which is
# not required for the P12 -- it's for operators) stays symmetrical.
$clientP12Bytes = [System.IO.File]::ReadAllBytes($clientP12Path)
$clientP12B64   = [System.Convert]::ToBase64String($clientP12Bytes)
Set-KvSecretValueIfAbsent -VaultName $kvName -Name $clientP12SecretName    -Value $clientP12B64                                  -ContentType 'application/x-pkcs12'

$clientP12Pwd = (Get-Content -Path $clientP12PwdPath -Raw).Trim()
Set-KvSecretValueIfAbsent -VaultName $kvName -Name $clientP12PwdSecretName -Value $clientP12Pwd

# The CA *private* key is not uploaded.
# The CA key stays only in ./temp/ so the local user can re-issue keys if needed.

Write-Verbose "Deploy strongSwan certificate material complete."

Write-Output "strongSwan cert material ready in '$TempPath' and Key Vault '$kvName':"
Write-Output "  CA cert            : $caCertSecretName"
Write-Output "  Server cert        : $serverCertSecretName"
Write-Output "  Server key         : $serverKeySecretName"
Write-Output "  Client 001 PKCS#12 : $clientP12SecretName (base64)"
Write-Output "  Client 001 P12 pwd : $clientP12PwdSecretName"
