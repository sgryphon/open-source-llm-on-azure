## ADDED Requirements

### Requirement: The capability SHALL provide two ordered PowerShell scripts in `b-shared/`

The `vpn-gateway` capability SHALL be delivered as two PowerShell scripts in the `b-shared/` folder, numbered in dependency order:

- `b-shared/04-Deploy-Certificate.ps1` — generates cert material locally and uploads to Key Vault.
- `b-shared/05-Deploy-StrongSwanVm.ps1` — deploys the Azure resources (NIC, NSG rules, VM, cloud-init) that consume the cert material.

Both scripts SHALL follow the project script conventions defined in `AGENTS.md` (`#!/usr/bin/env pwsh`, `[CmdletBinding()]`, `$ErrorActionPreference='Stop'`, comment-based help, `Write-Verbose` on every significant step, env-var fallback on every parameter, Azure CLI for all Azure operations).

The previous placeholder `b-shared/04-Deploy-StrongSwanVm.ps1` (copied from a Leshan deployment) SHALL be replaced; no script named `04-Deploy-StrongSwanVm.ps1` exists after this change.

#### Scenario: Directory listing shows the two VPN scripts in run order

- **WHEN** a developer runs `ls b-shared/`
- **THEN** `04-Deploy-Certificate.ps1` appears before `05-Deploy-StrongSwanVm.ps1` in numeric order
- **AND** no file named `04-Deploy-StrongSwanVm.ps1` remains

#### Scenario: Both scripts expose help

- **WHEN** a developer runs `Get-Help ./b-shared/04-Deploy-Certificate.ps1 -Full` or `Get-Help ./b-shared/05-Deploy-StrongSwanVm.ps1 -Full`
- **THEN** synopsis, description, notes, and at least one example are displayed for each

### Requirement: `04-Deploy-Certificate.ps1` SHALL generate cert material locally into `./temp/`

`04-Deploy-Certificate.ps1` SHALL generate the following artifacts into the repo-root `./temp/` directory (path configurable via `-TempPath` / `DEPLOY_TEMP_PATH`, default repo-root `temp/`):

| File                                              | Contents                                                          |
|---------------------------------------------------|-------------------------------------------------------------------|
| `strongswan-ca.key` / `strongswan-ca.pem`         | CA keypair, RSA 4096, 10-year validity                            |
| `strongswan-server.key` / `strongswan-server.pem` | Server cert signed by the CA, 5-year validity, SANs per below     |
| `strongswan-client-001.key` / `.pem` / `.p12`     | Initial client keypair + PKCS#12 bundle, 1-year validity          |
| `strongswan-client-001-p12-password.txt`          | PKCS#12 password (generated via `openssl rand -base64 24` on first run) |

The server certificate SANs SHALL include every public FQDN that will be assigned to the VM by `05-Deploy-StrongSwanVm.ps1` for the same parameter set:

- `strongswan-<OrgId>-<Environment>.<Location>.cloudapp.azure.com` (IPv6 PIP FQDN).
- `strongswan-<OrgId>-<Environment>-ipv4.<Location>.cloudapp.azure.com` (IPv4 PIP FQDN) — included only when `-AddPublicIpv4` is `$true`.

Cert generation SHALL use `pki` (from the `strongswan-pki` package) for key and cert generation, and `openssl pkcs12 -export` for the PKCS#12 bundle.

#### Scenario: First run generates every file under ./temp/

- **GIVEN** `./temp/` does not exist or is empty
- **WHEN** `./b-shared/04-Deploy-Certificate.ps1 -Environment Dev -OrgId 0xabcd -Location australiaeast` runs
- **THEN** the eight files listed above are present in `./temp/`
- **AND** the server `.pem` lists both the IPv6 and IPv4 FQDNs as `subjectAltName: DNS:` entries

#### Scenario: Server cert SANs omit IPv4 when -AddPublicIpv4 is $false

- **WHEN** `04-Deploy-Certificate.ps1` runs with `-AddPublicIpv4:$false`
- **THEN** the server cert SANs contain only the IPv6 FQDN

### Requirement: `04-Deploy-Certificate.ps1` SHALL be idempotent on both generation and upload

Re-running `04-Deploy-Certificate.ps1` against an already-initialised `./temp/` SHALL NOT regenerate any existing file and SHALL NOT overwrite Key Vault secrets that already exist. Each generation step SHALL be guarded by a file-existence check; each `az keyvault secret set` SHALL be preceded by `az keyvault secret show` and skipped if a value exists at that name.

Forced regeneration SHALL require the operator to delete files from `./temp/` (and optionally purge Key Vault secrets) before re-running. The script SHALL NOT delete any files itself.

#### Scenario: Re-running is a no-op when temp and Key Vault are already populated

- **GIVEN** `04-Deploy-Certificate.ps1` has previously succeeded for `-Environment Dev`
- **WHEN** the same command is run again with the same parameters
- **THEN** the script exits with code 0
- **AND** no file in `./temp/` is modified (mtime unchanged)
- **AND** no new version is created for any `strongswan-dev-*` Key Vault secret

#### Scenario: Partial state is completed without regenerating existing files

- **GIVEN** `./temp/strongswan-ca.pem` exists but the server cert files do not
- **WHEN** `04-Deploy-Certificate.ps1` runs
- **THEN** the existing CA files are left untouched and the server cert is issued using the existing CA

### Requirement: `04-Deploy-Certificate.ps1` SHALL upload cert material to Key Vault with deterministic secret names

`04-Deploy-Certificate.ps1` SHALL upload the following secrets to the shared Key Vault provisioned by `02-Deploy-KeyVault.ps1` (named per CAF conventions for the `<Purpose>`/`<Environment>`/`<Instance>` parameter set). `<env>` below is the lowercased value of `-Environment`.

| Key Vault secret name                       | Contents                            | Content-type              |
|---------------------------------------------|-------------------------------------|---------------------------|
| `strongswan-<env>-ca-cert`                  | CA cert, PEM                        | `application/x-pem-file`  |
| `strongswan-<env>-server-cert`              | Server cert, PEM                    | `application/x-pem-file`  |
| `strongswan-<env>-server-key`               | Server private key, PEM             | `application/x-pem-file`  |
| `strongswan-<env>-client-001-p12`           | Initial client PKCS#12, base64      | `application/x-pkcs12`    |
| `strongswan-<env>-client-001-p12-password`  | PKCS#12 password (plaintext)        | (none)                    |

The CA **private key** SHALL NOT be uploaded to Key Vault.

#### Scenario: All five secrets exist in Key Vault after a successful run

- **WHEN** `04-Deploy-Certificate.ps1 -Environment Dev` completes successfully against an empty Key Vault
- **THEN** `az keyvault secret show` returns a value for each of the five secret names listed above
- **AND** no secret named `strongswan-dev-ca-key` exists

### Requirement: `05-Deploy-StrongSwanVm.ps1` SHALL deploy a dual-stack IKEv2 VPN VM

`05-Deploy-StrongSwanVm.ps1` SHALL, idempotently via Azure CLI, deploy into the shared resource group and gateway subnet produced by earlier scripts:

- A Linux VM running Ubuntu LTS (image `UbuntuLTS` or equivalent), with size from `-VmSize` (default `Standard_D2s_v6`).
- A primary NIC in the gateway subnet with **both** an IPv4 and an IPv6 IP configuration.
- A public IPv6 Standard SKU address with DNS label `strongswan-<OrgId>-<Environment>`.
- A public IPv4 Standard SKU address with DNS label `strongswan-<OrgId>-<Environment>-ipv4` when `-AddPublicIpv4` is `$true`.
- Azure-level **IP forwarding** enabled on the NIC (`az network nic update --ip-forwarding true`).
- A **system-assigned managed identity** on the VM.
- CAF-aligned tags on every resource it creates, matching the tag dictionary used by `03-Deploy-GatewaySubnet.ps1`.

The script SHALL consume — but SHALL NOT create — the gateway subnet, the gateway NSG, the virtual network, the Key Vault, and the cert secrets.

#### Scenario: VM comes up with dual-stack public addressing and managed identity

- **WHEN** `05-Deploy-StrongSwanVm.ps1 -VpnUserPassword <pw>` completes successfully with default parameters
- **THEN** `az vm show -d` reports both an IPv4 public IP and an IPv6 public IP
- **AND** `az network nic show` reports `enableIPForwarding=true`
- **AND** `az vm identity show` reports a non-empty `principalId`

### Requirement: `05-Deploy-StrongSwanVm.ps1` SHALL add idempotent NSG rules for IKEv2

`05-Deploy-StrongSwanVm.ps1` SHALL add two inbound rules to the existing gateway NSG (named per `03-Deploy-GatewaySubnet.ps1`):

- `AllowIKE` — priority 2100, Allow, Inbound, protocol UDP, source `*`, destination port `500`.
- `AllowIPsecNatT` — priority 2101, Allow, Inbound, protocol UDP, source `*`, destination port `4500`.

Each rule SHALL be preceded by an `az network nsg rule show` pre-check and skipped if already present. The script SHALL NOT add, remove, or modify any other NSG rule.

#### Scenario: Re-run does not duplicate the IKE rules

- **GIVEN** `05-Deploy-StrongSwanVm.ps1` has previously succeeded
- **WHEN** the same command is run again with the same parameters
- **THEN** `az network nsg rule list` shows exactly one `AllowIKE` and one `AllowIPsecNatT` rule
- **AND** neither rule was modified (rule etag unchanged)

### Requirement: `05-Deploy-StrongSwanVm.ps1` SHALL grant the VM's managed identity read access to the VPN secrets

`05-Deploy-StrongSwanVm.ps1` SHALL grant the VM's system-assigned managed identity the RBAC role `Key Vault Secrets User`, scoped to the shared Key Vault, for the VPN secrets created by `04-Deploy-Certificate.ps1`. The role assignment SHALL be created idempotently (skipped if the assignment already exists for the same principal and scope).

The script SHALL NOT grant the managed identity any wider access than read-secrets on this vault.

#### Scenario: Managed identity can read CA and server cert secrets

- **WHEN** `05-Deploy-StrongSwanVm.ps1` completes successfully
- **THEN** `az role assignment list --assignee <vm-mi-principal-id>` includes a `Key Vault Secrets User` entry scoped to the shared Key Vault
- **AND** no entries grant write, delete, or certificate-management permissions

### Requirement: The VM SHALL retrieve cert material from Key Vault via its managed identity at first boot

Cloud-init executed on the VM SHALL install the Azure CLI and use `az login --identity` followed by `az keyvault secret download` to retrieve, at first boot, into the specified paths:

- `strongswan-<env>-ca-cert` → `/etc/swanctl/x509ca/ca.pem` (mode 644)
- `strongswan-<env>-server-cert` → `/etc/swanctl/x509/server.pem` (mode 644)
- `strongswan-<env>-server-key` → `/etc/swanctl/private/server.key` (mode 600)

Cert material SHALL NOT be generated on the VM, and SHALL NOT be passed to the VM as cloud-init substitution tokens.

The retrieval step SHALL retry on transient failure (including RBAC propagation delay) with a capped total wait of at least 120 seconds.

#### Scenario: Cert material is present on the VM after boot

- **WHEN** `05-Deploy-StrongSwanVm.ps1` completes and cloud-init reports `status: done`
- **THEN** `/etc/swanctl/x509ca/ca.pem`, `/etc/swanctl/x509/server.pem`, and `/etc/swanctl/private/server.key` all exist on the VM
- **AND** `/etc/swanctl/private/server.key` has mode `0600`

#### Scenario: Cloud-init does not generate certificates

- **WHEN** cloud-init runs on the VM
- **THEN** the cloud-init config file contains no invocation of `pki --gen`, `pki --self`, `pki --issue`, or `openssl req -new`

### Requirement: The VM SHALL accept IKEv2 with server-cert + EAP-MSCHAPv2 and with server-cert + client-cert

The strongSwan configuration written by cloud-init SHALL expose one IKEv2 road-warrior connection whose `remote` stanzas accept **both** of the following client authentications (the client picks at connect time), while the `local` stanza always authenticates the server with the server certificate fetched from Key Vault:

- **EAP-MSCHAPv2** using a single username/password seeded from the script parameters `-VpnUsername` (default `vpnuser`) and `-VpnUserPassword` (required).
- **Pubkey (client certificate)** signed by the CA cert fetched from Key Vault.

The VPN clients SHALL receive virtual IPs from the pool, DNS servers appropriate for the VNet (Azure-provided 168.63.129.16 for IPv4 at minimum), and split-routing pushed to the VPN subnets.

#### Scenario: EAP-MSCHAPv2 client connects with username and password

- **GIVEN** the VM is deployed and reachable on UDP 500 / 4500
- **WHEN** an IKEv2 client authenticates with username `vpnuser` and the configured password, trusting the CA cert
- **THEN** the IKE SA and a CHILD SA are established
- **AND** the client is assigned a virtual IPv4 and a virtual IPv6 from the configured pools

#### Scenario: Client-cert client connects without a password

- **GIVEN** the VM is deployed and the initial client `.p12` has been imported on a client
- **WHEN** the client authenticates using the client certificate (no username/password)
- **THEN** the IKE SA and a CHILD SA are established

### Requirement: The VPN client virtual IP pool SHALL be a deterministic routed range, not an Azure VNet

The VPN client virtual IP pool SHALL be a pure strongSwan construct declared in `swanctl.conf` under `pools`; the capability SHALL NOT create any Azure VNet, subnet, or NSG for the pool.

For a `UlaGlobalId` decomposed as `gg gggg gggggg`, and default `-VpnVnetId 02`, the *subnet identity* used for iptables/ip6tables FORWARD and NAT scope SHALL be:

- IPv4 subnet: `10.<gg-decimal>.<VpnVnetId-decimal>.0/24` (e.g. `10.171.2.0/24` when `gg=0xab`).
- IPv6 subnet: `fd<gg>:<gggg>:<gggggg>:<VpnVnetId>00::/64`.

The *allocation range* declared to strongSwan's `pools` SHALL be strictly narrower, leaving room inside the same subnet for future static assignments. Default allocation ranges:

- IPv4 pool: upper half of the subnet (e.g. `10.171.2.128/25`).
- IPv6 pool: a `/116` starting at `::1000` (e.g. `fd<gg>:<gggg>:<gggggg>:0200::1000/116`).

IPv6 subnets SHALL always be `/64` — smaller IPv6 subnets SHALL NOT be used. Client addresses SHALL NOT be hardcoded; they SHALL be computed in the PowerShell script from `-UlaGlobalId` and `-VpnVnetId`.

#### Scenario: Pool derivation matches the UlaGlobalId scheme

- **GIVEN** `-UlaGlobalId abcdef0123` and `-VpnVnetId 02`
- **WHEN** `05-Deploy-StrongSwanVm.ps1` produces the cloud-init file
- **THEN** the substituted IPv4 subnet is `10.171.2.0/24` and the IPv6 subnet is `fdab:cdef:0123:0200::/64`
- **AND** the substituted IPv4 pool is `10.171.2.128/25` and the IPv6 pool is `fdab:cdef:0123:0200::1000/116`

#### Scenario: No Azure VNet or subnet is created for the pool

- **WHEN** `05-Deploy-StrongSwanVm.ps1` completes
- **THEN** the resource group contains no new VNet or subnet beyond those produced by `a-infrastructure/` and `03-Deploy-GatewaySubnet.ps1`

### Requirement: The VM SHALL enable IP forwarding at both the Azure NIC level and the OS level

`05-Deploy-StrongSwanVm.ps1` SHALL set `enableIPForwarding=true` on the VM's NIC. Cloud-init SHALL write a sysctl drop-in file (`/etc/sysctl.d/99-strongswan.conf`) containing:

- `net.ipv4.ip_forward = 1`
- `net.ipv6.conf.all.forwarding = 1`
- `net.ipv6.conf.default.forwarding = 1`

and SHALL apply it via `sysctl --system` in the same boot.

#### Scenario: Both forwarding levels are active on the VM

- **WHEN** the VM has finished first boot
- **THEN** `az network nic show` reports `enableIPForwarding=true`
- **AND** `sysctl net.ipv4.ip_forward`, `sysctl net.ipv6.conf.all.forwarding`, and `sysctl net.ipv6.conf.default.forwarding` all return `1` on the VM

### Requirement: The VM SHALL NAT IPv4 client traffic and forward IPv6 client traffic

Cloud-init SHALL install `iptables-persistent` and configure persistent rules such that:

- IPv4: traffic originating from the IPv4 VPN subnet and exiting the primary interface is masqueraded (`iptables -t nat -A POSTROUTING -s <ipv4-subnet> -o eth0 -j MASQUERADE`).
- IPv4: forwarding is permitted in both directions between the IPv4 VPN subnet and the VNet.
- IPv6: forwarding is permitted in both directions between the IPv6 VPN `/64` and the VNet. IPv6 traffic SHALL NOT be NAT'd (no NAT66).
- UFW SHALL allow inbound `22/tcp`, `500/udp`, and `4500/udp`.

Rules SHALL be applied idempotently by cloud-init (rules written to `/etc/iptables/rules.v4` and `/etc/iptables/rules.v6` so they survive reboot).

#### Scenario: IPv4 traffic exits the VM NAT'd

- **GIVEN** a VPN client is connected and assigned an address from the IPv4 pool
- **WHEN** the client sends IPv4 traffic to a VNet resource
- **THEN** packet captures on the VNet resource show the strongSwan VM's IPv4 as the source

#### Scenario: IPv6 traffic is forwarded without NAT

- **GIVEN** a VPN client is connected and assigned an address from the IPv6 pool
- **WHEN** the client sends IPv6 traffic to a VNet resource
- **THEN** packet captures on the VNet resource show the client's ULA address as the source

### Requirement: Both scripts SHALL accept parameters with env-var fallback following project conventions

Every parameter on `04-Deploy-Certificate.ps1` and `05-Deploy-StrongSwanVm.ps1` SHALL have an environment-variable fallback of the form `DEPLOY_*` and a documented default. At minimum, the following parameters SHALL be exposed:

`04-Deploy-Certificate.ps1`:

| Parameter           | Env var                       | Default                                  |
|---------------------|-------------------------------|------------------------------------------|
| `-Purpose`          | `DEPLOY_PURPOSE`              | `LLM`                                    |
| `-Environment`      | `DEPLOY_ENVIRONMENT`          | `Dev`                                    |
| `-OrgId`            | `DEPLOY_ORGID`                | first 4 hex chars of subscription id     |
| `-Location`         | `DEPLOY_LOCATION`             | `australiaeast`                          |
| `-Instance`         | `DEPLOY_INSTANCE`             | `001`                                    |
| `-ServerDnsLabel`   | `DEPLOY_VPN_DNS_LABEL`        | `strongswan-<OrgId>-<Environment>`       |
| `-AddPublicIpv4`    | `DEPLOY_ADD_IPV4`             | `$true`                                  |
| `-TempPath`         | `DEPLOY_TEMP_PATH`            | `<repo>/temp`                            |

`05-Deploy-StrongSwanVm.ps1`:

| Parameter           | Env var                       | Default                                  |
|---------------------|-------------------------------|------------------------------------------|
| `-VpnUsername`      | `DEPLOY_VPN_USERNAME`         | `vpnuser`                                |
| `-VpnUserPassword`  | `DEPLOY_VPN_USER_PASSWORD`    | (required)                               |
| `-VpnVnetId`        | `DEPLOY_VPN_VNET_ID`          | `02`                                     |
| `-UlaGlobalId`      | `DEPLOY_GLOBAL_ID`            | first 10 hex chars of `SHA256(sub-id)`   |
| `-ServerDnsLabel`   | `DEPLOY_VPN_DNS_LABEL`        | `strongswan-<OrgId>-<Environment>`       |
| `-VmSize`           | `DEPLOY_VM_SIZE`              | `Standard_D2s_v6`                        |
| `-AdminUsername`    | `DEPLOY_ADMIN_USERNAME`       | `admin`                                  |
| `-AddPublicIpv4`    | `DEPLOY_ADD_IPV4`             | `$true`                                  |
| `-ShutdownUtc`      | `DEPLOY_SHUTDOWN_UTC`         | `0900`                                   |
| `-ShutdownEmail`    | `DEPLOY_SHUTDOWN_EMAIL`       | `''`                                     |

Neither script SHALL accept a `-WebPassword` parameter or respect `DEPLOY_WEB_PASSWORD`.

#### Scenario: Environment variables override defaults consistently across both scripts

- **GIVEN** `$env:DEPLOY_ENVIRONMENT = 'Prod'`, `$env:DEPLOY_ORGID = '0xbeef'`, `$env:DEPLOY_ADD_IPV4 = 'true'`
- **WHEN** `04-Deploy-Certificate.ps1` and then `05-Deploy-StrongSwanVm.ps1 -VpnUserPassword …` both run with no other arguments
- **THEN** the secret names produced by `04` are `strongswan-prod-*`
- **AND** the server cert SANs include `strongswan-0xbeef-prod.australiaeast.cloudapp.azure.com` and `strongswan-0xbeef-prod-ipv4.australiaeast.cloudapp.azure.com`
- **AND** `05` uses the same FQDNs when creating public IPs

### Requirement: The cloud-init template SHALL use placeholder tokens and be rendered to `b-shared/temp/`

`b-shared/data/strongswan-cloud-init.txt` SHALL be a static template containing the tokens listed below. `05-Deploy-StrongSwanVm.ps1` SHALL render a substituted copy to `b-shared/temp/strongswan-cloud-init.txt~` and pass it to `az vm create --custom-data`. The rendered file SHALL NOT be committed (the `temp/` path SHALL be gitignored).

Required tokens:

- `#INIT_VPN_USERNAME#`
- `#INIT_VPN_PASSWORD#`
- `#INIT_VPN_SUBNET_IPV4#`
- `#INIT_VPN_SUBNET_IPV6#`
- `#INIT_VIP_POOL_IPV4#`
- `#INIT_VIP_POOL_IPV6#`
- `#INIT_SERVER_FQDNS#`
- `#INIT_KEY_VAULT_NAME#`
- `#INIT_CA_SECRET_NAME#`
- `#INIT_SERVER_CERT_SECRET_NAME#`
- `#INIT_SERVER_KEY_SECRET_NAME#`
- `#INIT_ADMIN_USER#`

All Leshan-era tokens (`#INIT_HOST_NAMES#`, `#INIT_PASSWORD_INPUT#`) SHALL be absent from the template.

The template SHALL install `strongswan`, `strongswan-swanctl`, `libcharon-extra-plugins`, `libstrongswan-extra-plugins`, `iptables-persistent`, and `azure-cli`, and SHALL NOT install `caddy`, `default-jre`, or any Leshan artifact.

#### Scenario: Rendered cloud-init has all tokens substituted

- **WHEN** `05-Deploy-StrongSwanVm.ps1` runs
- **THEN** `b-shared/temp/strongswan-cloud-init.txt~` is produced
- **AND** the rendered file contains no string matching `#INIT_[A-Z_]+#`

#### Scenario: Template omits Leshan-era packages and tokens

- **WHEN** `b-shared/data/strongswan-cloud-init.txt` is inspected
- **THEN** it contains no occurrence of `caddy`, `default-jre`, `leshan`, `#INIT_HOST_NAMES#`, or `#INIT_PASSWORD_INPUT#`

### Requirement: `./temp/` SHALL be gitignored at the repository root

The repository `.gitignore` SHALL include a rule that excludes the repo-root `temp/` directory and everything under it. `b-shared/temp/` (where cloud-init renders occur) SHALL also be excluded.

#### Scenario: Files in `./temp/` are not tracked by git

- **GIVEN** the repo has had `04-Deploy-Certificate.ps1` run and `./temp/` contains generated keys
- **WHEN** a developer runs `git status`
- **THEN** no files under `./temp/` appear as untracked or modified

### Requirement: The devcontainer SHALL include tooling for local cert generation

The devcontainer build (Dockerfile, feature config, or equivalent) SHALL install `openssl` and the `strongswan-pki` package so that `04-Deploy-Certificate.ps1` can run inside it without additional setup. The operator is expected to rebuild the devcontainer after this change is merged; that requirement SHALL be stated in the `.NOTES` section of `04-Deploy-Certificate.ps1`.

#### Scenario: `pki` and `openssl` are on PATH in a fresh devcontainer

- **GIVEN** a developer has just rebuilt the devcontainer from the `main` branch
- **WHEN** they run `which pki` and `which openssl`
- **THEN** both commands return a non-empty path and exit 0

### Requirement: `05-Deploy-StrongSwanVm.ps1` SHALL be re-runnable without duplicating resources

Re-running `05-Deploy-StrongSwanVm.ps1` against a subscription where it has previously succeeded SHALL complete with exit code 0 and SHALL NOT duplicate the VM, NIC, public IPs, NSG rules, or role assignment. Each `az ... create` call SHALL be preceded by an `az ... show` pre-check.

#### Scenario: Second run is a no-op

- **GIVEN** `05-Deploy-StrongSwanVm.ps1 -VpnUserPassword <pw>` has previously succeeded
- **WHEN** the same command is run again with the same parameters
- **THEN** the script exits with code 0 and no new VM, NIC, public IP, NSG rule, or role assignment is created

### Requirement: The capability SHALL NOT create resources outside its explicit scope

`04-Deploy-Certificate.ps1` and `05-Deploy-StrongSwanVm.ps1` together SHALL create, in Azure, only: a VM, its OS disk, one NIC, one or two public IPs, two NSG rules on the existing gateway NSG, five Key Vault secrets, and one role assignment. They SHALL NOT create or modify resource groups, VNets, subnets, Key Vault itself, Azure Monitor, UDRs, or any resource in the workload resource group.

#### Scenario: Clean subscription contains only capability-scoped additions after deploy

- **GIVEN** `a-infrastructure/`, `b-shared/01..03` have been run
- **WHEN** `04-Deploy-Certificate.ps1` and `05-Deploy-StrongSwanVm.ps1` both complete
- **THEN** `az resource list -g rg-llm-shared-<env>-001` shows exactly the pre-existing resources plus: one VM, one OS disk, one NIC, one or two public IPs
- **AND** no new VNet, subnet, UDR, or resource group has been created
