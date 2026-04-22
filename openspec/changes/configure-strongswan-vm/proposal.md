## Why

The project needs a working point-to-site VPN so a developer's local machine can reach services in the Azure workload VNet privately, without exposing LLM endpoints to the public internet. The README (`## VPN options`) already selected **strongSwan on an Azure VM** as the chosen approach, and a placeholder script `b-shared/04-Deploy-StrongSwanVm.ps1` exists that was copy-pasted from a Leshan LwM2M deployment and partially renamed; as-is it still installs Caddy + Java + Leshan and opens CoAP ports, not an IKEv2 gateway. This change replaces that placeholder with a working strongSwan deployment.

No first-party Azure template or quickstart deploys strongSwan (confirmed via Microsoft Marketplace and Azure Quickstart Templates — only one unrelated third-party paid image exists). Cloud-init on a vanilla Ubuntu LTS VM remains the right approach and matches the project's "no third-party dependencies" principle.

## What Changes

- **Split** the placeholder into two scripts with independent lifecycles:
  - **New** `b-shared/04-Deploy-Certificate.ps1` — generates the VPN CA and server/client certificates **locally** (on the operator's machine / devcontainer) into `./temp/`, then uploads them to the existing shared Key Vault. Idempotent (skip generation if PEMs already in `./temp/`, skip upload if secret already in Key Vault).
  - **Rewrite + rename** `b-shared/04-Deploy-StrongSwanVm.ps1` → `b-shared/05-Deploy-StrongSwanVm.ps1` — deploys the Ubuntu VM, NIC, NSG rules, and cloud-init that **pulls** the server cert and CA from Key Vault using a system-assigned managed identity.
- Add `temp/` (project root) to `.gitignore` so generated keys and temp cloud-init files are never committed.
- Update the devcontainer to include the tooling needed for local cert generation: `openssl` (for self-signed CA, PKCS#12 packaging) and `strongswan-pki` package (provides the `pki` binary; Azure CLI and PowerShell are already present). Operator rebuilds the container before running the new scripts.
- Replace the Leshan-specific NSG rule (`AllowLwM2M`, UDP 5683/5684) with IKEv2 rules added by `05-Deploy-StrongSwanVm.ps1`: **UDP 500** (IKE) and **UDP 4500** (NAT-T / ESP-over-UDP). Both created idempotently (skip if present).
- Enable **Azure-level IP forwarding** on the VM's NIC (`az network nic update --ip-forwarding true`) so the VM can forward tunnelled traffic into the VNet.
- Remove the dead copy-paste references to `$Region`, `$prefixByte`, `$VnetId`, `$SubnetId`, and the broken `$gatewaySubnetIPv4` calculation. Addressing info comes from the subnet returned by `az network vnet subnet show`.
- Drop the `$WebPassword` / Caddy basic-auth flow entirely. Add a `-VpnUserPassword` parameter (env `DEPLOY_VPN_USER_PASSWORD`) and `-VpnUsername` (default `vpnuser`) on the VM script for the EAP-MSCHAPv2 credential; this is seeded into the VM's `swanctl.conf` via cloud-init placeholders (not stored in Key Vault for now — documented in design as an Open Question).
- Grant the VM's **system-assigned managed identity** `get` permission on the VPN-related Key Vault secrets so cloud-init can retrieve the cert material at first boot.
- Rewrite `b-shared/data/strongswan-cloud-init.txt` to:
  - Install `strongswan`, `strongswan-swanctl`, `libcharon-extra-plugins`, `libstrongswan-extra-plugins`, `iptables-persistent`, and `azure-cli` (remove Caddy, `default-jre`, Leshan).
  - Enable OS-level IP forwarding (`net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`) via `/etc/sysctl.d/`.
  - Use the VM's managed identity (`az login --identity`) to fetch the **CA cert** and **server cert + key** from Key Vault and place them under `/etc/swanctl/x509ca/` and `/etc/swanctl/x509/` + `/etc/swanctl/private/`.
  - Write `/etc/swanctl/swanctl.conf` with an IKEv2 road-warrior connection supporting **both** EAP-MSCHAPv2 (username/password seeded via `#INIT_VPN_USER#` / `#INIT_VPN_PASSWORD#`) **and** client-cert pubkey auth against the fetched CA. The server always authenticates with its cert.
  - Assign clients from a deterministic **virtual IP pool** (IPv4 `#INIT_VIP_POOL_IPV4#`, IPv6 `#INIT_VIP_POOL_IPV6#`) passed in from the PowerShell script. The pool is a **routed address range entirely internal to the VPN VM** (strongSwan handles allocation; IPv4 egress is MASQUERADE'd through the VM's NIC, IPv6 is forwarded directly). It does **not** require an Azure VNet or subnet.
  - Configure `iptables` MASQUERADE (IPv4) + FORWARD and `ip6tables` FORWARD rules via `iptables-persistent`.
  - Open UFW ports `22/tcp`, `500/udp`, `4500/udp`.
  - Enable and start `strongswan` + `swanctl --load-all`.
- Derive the client VIP pool addresses in the VM PowerShell script from the same subscription ULA Global ID used by the gateway subnet (reusing the hash pattern from `03-Deploy-GatewaySubnet.ps1`), with a new `-VpnVnetId` parameter (default `02`) to keep the VPN pool distinct from the hub VNet range.
- On completion of `05-Deploy-StrongSwanVm.ps1`, print the VPN server FQDN(s), the Key Vault secret names containing the CA cert and client `.p12` bundle, and a one-liner showing how to download them.
- Update the SYNOPSIS / NOTES comment blocks of both PS1 scripts to describe strongSwan (currently the placeholder still says "Eclipse Leshan LwM2M server").

## Capabilities

### New Capabilities
- `vpn-gateway`: Deployment and configuration of a point-to-site IKEv2 VPN gateway (strongSwan on Ubuntu VM) that sits in the hub gateway subnet, authenticates remote clients via server certificate + EAP-MSCHAPv2 (and optionally client cert), assigns clients an IP from a deterministic virtual pool, and forwards their traffic (IPv4 + IPv6) into the Azure VNet. Includes publishing the CA / server / client certificate material to Key Vault for client provisioning.

### Modified Capabilities
<!-- None. `core-infrastructure` (gateway subnet, NSG, VNet) is consumed as-is; no requirement changes. -->

## Impact

- **Files created / rewritten**:
  - `b-shared/04-Deploy-Certificate.ps1` (new)
  - `b-shared/05-Deploy-StrongSwanVm.ps1` (rewritten from the current `04-Deploy-StrongSwanVm.ps1`; old file deleted)
  - `b-shared/data/strongswan-cloud-init.txt` (rewritten)
  - `.gitignore` (add `temp/`)
  - `.devcontainer/` Dockerfile or feature config (add `openssl`, `strongswan-pki`)
- **New prerequisites**: `04-Deploy-Certificate.ps1` must run before `05-Deploy-StrongSwanVm.ps1`. Both require `02-Deploy-KeyVault.ps1` to have run. `05` must also run after `03-Deploy-GatewaySubnet.ps1`.
- **Key Vault wiring**: The VM's system-assigned managed identity is granted `get` on the VPN-related secrets by `05`. The operator running `04` already has secret `set` permissions from deploying the Key Vault.
- **Networking**: `05` adds UDP 500/4500 rules to the gateway NSG; enables IP forwarding on the VM NIC. No VNet, subnet, or UDR changes (VPN client pool is an internal routed range — confirmed no Azure subnet needed).
- **Secrets / parameters**:
  - New env vars: `DEPLOY_VPN_USER_PASSWORD` (required by `05`), `DEPLOY_VPN_USERNAME` (optional, default `vpnuser`), `DEPLOY_VPN_VNET_ID` (optional, default `02`).
  - Removed: `DEPLOY_WEB_PASSWORD`.
- **Cost**: Unchanged (one small Linux VM + one public IP, per the README).
- **Downstream**: Unblocks the workload-side UDR step mentioned in `README.md` (`vpn/03-client-routes.ps1`), which is out of scope for this change.
- **Out of scope**: Automated client device provisioning (mobileconfig / Windows PowerShell VPN cmdlets), cert rotation, high availability / multi-region, and storing EAP-MSCHAPv2 credentials in Key Vault (documented as an Open Question in design).
