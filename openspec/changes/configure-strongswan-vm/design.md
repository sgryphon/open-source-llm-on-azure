## Context

The project needs a point-to-site VPN so a developer's laptop can reach the Azure workload VNet privately. The README selected **strongSwan on an Azure VM** as the MVP VPN option. A placeholder `b-shared/04-Deploy-StrongSwanVm.ps1` + `b-shared/data/strongswan-cloud-init.txt` exist but were copy-pasted from a Leshan LwM2M deployment and still install Caddy/Java/Leshan, open CoAP ports, and reference undeclared variables (`$Region`, `$VnetId`, `$SubnetId`, `$prefixByte`).

Confirmed by research (Azure Marketplace + Azure Quickstart Templates): **no first-party template** deploys strongSwan. The only published option is one unrelated paid third-party image, which conflicts with the project's "no third-party dependencies" principle. Therefore the approach is: a vanilla Ubuntu LTS VM, configured in cloud-init.

Surrounding constraints:

- The gateway subnet, NSG, and addressing scheme are already provisioned by `04-Deploy-GatewaySubnet.ps1` (renamed from `03-…` as part of this change to make room for the VPN identity script); this change consumes them read-only.
- Script style (CAF naming, tagging, parameter + env-var fallback, `Write-Verbose`, `$ErrorActionPreference='Stop'`, Azure CLI only) is already established by `02-Deploy-KeyVault.ps1` and `04-Deploy-GatewaySubnet.ps1` and must be preserved.
- Addressing model (IPv6 ULA `fdgg:gggg:gggggg:vvss::/64` + IPv4 `10.<gg>.<vv>.0/24` derived from `UlaGlobalId`) is the project-wide pattern.
- The Key Vault from `02-Deploy-KeyVault.ps1` already exists in the shared RG and is the natural place to publish generated certs/credentials.

## Goals / Non-Goals

**Goals:**

- Produce three cooperating, idempotent PowerShell scripts:
  - `b-shared/03-Deploy-VpnIdentity.ps1` — creates the VPN VM's user-assigned managed identity and grants it `get, list` on Key Vault secrets via an access-policy entry.
  - `b-shared/05-Deploy-Certificate.ps1` — local cert generation + Key Vault upload.
  - `b-shared/06-Deploy-StrongSwanVm.ps1` — stands up a working IKEv2 VPN gateway that consumes the certs, binding the pre-provisioned UAMI.
- Support **both** authentication styles in one deployment:
  - Server-cert + **EAP-MSCHAPv2** (username/password) — simplest for onboarding, works with native IKEv2 clients on Windows, macOS, iOS, Android, Linux.
  - Server-cert + **client-cert** (pubkey) auth — stronger, same native clients.
- Tunnel **both IPv4 and IPv6** client traffic into the VNet (dual-stack parity with the rest of the landing zone).
- Publish the CA cert, server cert, server key, and an initial client PKCS#12 bundle + its password to **Azure Key Vault** so both the VM (via managed identity) and operators (for client provisioning) can retrieve what they need.
- Keep the existing script/file structure: scripts in `b-shared/` with numeric prefixes, cloud-init template under `b-shared/data/`, temp VM-init file produced in `b-shared/temp/`, same parameter conventions, same tag dictionary, same auto-shutdown block. Local cert material in `./temp/` at repo root (gitignored).
- Remain **re-runnable**: a second run of either script against the same environment must not error and must not duplicate resources; cert regeneration requires explicit deletion of `./temp/`.

**Non-Goals:**

- Automated client device provisioning (`.mobileconfig`, Windows `Add-VpnConnection`, etc.) — out of scope; documentation-only.
- High availability, active/standby pairs, or multi-region deployment.
- Credential rotation, cert renewal, or revocation workflows (certs are generated once at first boot with a long lifetime; rotation is a future change).
- Site-to-site IPsec (this is P2S / road-warrior only).
- UDRs on the workload subnet for the VPN client pool (`vpn/03-client-routes.ps1` per the README is a separate future change).
- Modifying `core-infrastructure`, the gateway subnet, or the existing NSG beyond adding two rules.
- Hosting a separate RADIUS server — EAP-MSCHAPv2 credentials are seeded directly into `swanctl.conf`.

## Decisions

### D1. Ubuntu LTS + cloud-init, not a Marketplace image or custom managed image

**Chosen:** Deploy the Azure CLI default Ubuntu LTS image and drive all configuration from cloud-init, exactly as the placeholder script already does.

**Alternatives considered:**

- *Marketplace "VPN Server IKEv2-MSCHAPv2" image* — Rejected: third-party, paid, not Microsoft-maintained, violates the project's no-third-party principle, and obscures configuration.
- *Custom managed VM image baked with Packer* — Rejected for MVP: adds build pipeline complexity; cloud-init already runs in under ~3 minutes on a B1s; we can migrate to a baked image later if boot time matters.
- *Azure VPN Gateway P2S* — Already rejected in the README (cost, IPv6 requires VpnGw1+).

**Rationale:** Cloud-init is transparent, diff-able, free, and the same pattern as the rest of this repo. All configuration lives in one readable text file that can be code-reviewed.

### D2. Auth = server cert + EAP-MSCHAPv2 **and** client-cert, single connection

**Chosen:** Configure one `swanctl` connection with two `remote` authentication blocks — one requiring EAP-MSCHAPv2 (username/password), one requiring a client cert signed by the generated CA. The client chooses at connect time. The server always authenticates with its cert (IKEv2 mutual auth).

**Alternatives considered:**

- *EAP-MSCHAPv2 only* — Rejected: the user explicitly asked for native IKEv2 client-cert support as well.
- *EAP-TLS* — Equivalent security to raw client-cert pubkey auth but requires `eap-tls` plugin quirks on some clients. Pubkey auth is universally supported by native clients and simpler.
- *Two separate `swanctl` connections* — Works, but then clients must pick the right `remote_addrs` / ID. One connection with two `remote` blocks is what strongSwan's own road-warrior examples recommend.

**Rationale:** Satisfies "works with native clients + optional username/password onboarding" in a single deployment with no connection-selection gymnastics on the client side.

### D3. Certs generated **locally** (operator machine / devcontainer), not on the VM

**Chosen:** A new dedicated script `b-shared/05-Deploy-Certificate.ps1` runs on the operator's machine and generates, into `./temp/` at the repo root:

- `temp/strongswan-ca.key` + `temp/strongswan-ca.pem` — CA keypair (RSA 4096, 10-year validity, CN `strongSwan <OrgId> <env> CA`).
- `temp/strongswan-server.key` + `temp/strongswan-server.pem` — Server cert signed by the CA (5-year, SANs = every public FQDN of the VM public IPs, which are deterministic from script parameters and therefore known before the VM exists).
- `temp/strongswan-client-001.key` + `temp/strongswan-client-001.pem` + `temp/strongswan-client-001.p12` — Initial client keypair + PKCS#12 bundle (1-year, CN `client-<OrgId>-<env>-001`).
- `temp/strongswan-client-001-p12-password.txt` — Password protecting the PKCS#12 (generated via `openssl rand -base64 24` on first run, persisted so re-running is idempotent).

Idempotency: each generation step first checks whether the expected output file exists in `./temp/` and skips if so. This means a second invocation is a no-op; a forced regeneration means the operator manually deletes `./temp/`.

Upload: the same script then uploads the artifacts to Key Vault (`az keyvault secret set`), again idempotently — it calls `az keyvault secret show` first and skips if a value already exists at that name and version. (Rotation is an explicit future change; the MVP treats secrets as write-once.)

`./temp/` is added to `.gitignore` at the project root so private keys cannot accidentally be committed.

The **devcontainer** is updated to include `openssl` (present in most base images already; ensure it is) and the `strongswan-pki` package (provides `pki`, which produces the IKEv2-preferred cert extensions more cleanly than raw openssl). The operator rebuilds the devcontainer before running `05`.

**Alternatives considered:**

- *Generate on the VM at first boot* (the previous design) — Rejected per user feedback: couples the cert lifecycle to the VM lifecycle, makes re-creating the VM re-issue certs (breaking all clients), and requires a retrieval dance via `az vm run-command`. Local generation cleanly separates the two.
- *Use Azure Key Vault's issued-cert feature* — Still rejected for MVP: requires configuring an issuer; heavier than what this MVP needs.
- *Use `pki` exclusively, no openssl* — Possible but `pki` can't produce PKCS#12 directly; we use `pki` for cert generation and `openssl pkcs12 -export` for the client bundle.

**Rationale:** Certs survive VM rebuilds, rotation is opt-in, and the operator has direct visibility into what's about to be uploaded. `./temp/` + gitignore keeps the keys off the network entirely unless the operator explicitly pushes them.

### D4. VM retrieves its cert material from Key Vault via a user-assigned managed identity

**Chosen:** `03-Deploy-VpnIdentity.ps1` creates a **user-assigned managed identity** (UAMI) named `id-llm-strongswan-<env>-001` in the shared RG and grants it `get, list` on the shared Key Vault's secrets via `az keyvault set-policy --object-id <uami-principalId>`. `06-Deploy-StrongSwanVm.ps1` then binds this UAMI at VM-create time (`az vm create --assign-identity <uami-resourceId>`). Cloud-init uses the Azure CLI (installed as a package) to log in with the UAMI explicitly and download the artifacts:

```bash
az login --identity --username "$UAMI_CLIENT_ID"
az keyvault secret download --vault-name <kv> --name strongswan-<env>-ca-cert --file /etc/swanctl/x509ca/ca.pem
az keyvault secret download --vault-name <kv> --name strongswan-<env>-server-cert --file /etc/swanctl/x509/server.pem
az keyvault secret download --vault-name <kv> --name strongswan-<env>-server-key --file /etc/swanctl/private/server.key
chmod 600 /etc/swanctl/private/server.key
```

The UAMI's `clientId` is substituted into cloud-init via `#INIT_UAMI_CLIENT_ID#`.

Key Vault secret names (written by `05`, read by `06`):

| Secret name                                | Contents                              | Written by | Read by cloud-init |
|--------------------------------------------|---------------------------------------|------------|--------------------|
| `strongswan-<env>-ca-cert`                 | CA certificate, PEM                   | `05`       | yes                |
| `strongswan-<env>-server-cert`             | Server certificate, PEM               | `05`       | yes                |
| `strongswan-<env>-server-key`              | Server private key, PEM (unencrypted) | `05`       | yes                |
| `strongswan-<env>-client-001-p12`          | Initial client PKCS#12 bundle, base64 | `05`       | no (for operators) |
| `strongswan-<env>-client-001-p12-password` | PKCS#12 password                      | `05`       | no (for operators) |

EAP-MSCHAPv2 credentials are **not** stored in Key Vault in this MVP — they are passed as parameters to `06` and injected into `swanctl.conf` via cloud-init placeholders. (See Open Questions.)

**Alternatives considered:**

- *System-assigned managed identity (SA-MI) + RBAC (`Key Vault Secrets User`)* — The original design. Rejected for this project because: (a) the operator runs as Contributor via a group assignment and cannot create role assignments (`roleAssignments/write` is denied), and (b) SA-MI only materialises after `az vm create` returns, which forces the permission grant to race cloud-init's first `az login --identity` call — in RBAC mode that race is particularly painful because propagation can take up to a minute. Pre-creating a UAMI sidesteps both problems: permissions are granted before the VM exists, and access-policy mode is a pure management-plane write that Contributor *can* perform.
- *Azure VM `--secrets` + `az vm secret format`* — Cleaner in one way (the cert lands in a predictable path at boot with no cloud-init code) but requires the material to be stored as a Key Vault **certificate object** rather than a secret, which forces a specific import format (PFX) and makes the CA + server cert + server key split awkward.
- *Key Vault VM extension (`KeyVaultForLinux`)* — Polls on an interval; the right tool for rotation, but overkill for this one-shot fetch. Could be added in a future rotation-focused change.

**Rationale:** UAMI + access-policy is the most flexible and readable approach that also fits the project's Contributor-only permissions: it handles PEMs, keys, and PKCS#12 identically; cloud-init stays linear; permission propagation completes before the VM boots; and every `az ...` call involved is within Contributor's authority.

### D5. Client virtual IP pool is a routed range, **not** an Azure VNet/subnet

**Chosen:** The VPN client pool is a pure strongSwan construct. It is declared in `swanctl.conf` under `pools`, strongSwan allocates addresses to clients on connect, and traffic is bridged into the VNet by:

- IPv4: `iptables -t nat -A POSTROUTING -s <ipv4-subnet> -o eth0 -j MASQUERADE`. VNet resources see the VM's IPv4; no routing changes are needed in Azure.
- IPv6: `ip6tables -A FORWARD -s <ipv6-subnet> -j ACCEPT` + the symmetric reverse rule. VNet resources see the client's ULA address directly; this works because the pool's `/64` is derived from the same `UlaGlobalId` as the VNets and is reachable via existing peerings once a UDR is added on the workload subnet (that UDR is out of scope for this change; the VM itself will still be reachable without it).

No Azure VNet, subnet, or NSG is created for the pool. The subnet identity lives only inside the VM's strongSwan config and iptables rules.

**Addressing — two layers**

We distinguish the conceptual *subnet* (what routing and firewall rules reference) from the *allocation range* strongSwan actually hands out. For a given `UlaGlobalId` decomposed as `gg gggg gggggg`, and default `-VpnVnetId 02`:

|                               | IPv4                  | IPv6                                             |
|-------------------------------|-----------------------|--------------------------------------------------|
| **VPN "subnet"** (routing, NAT/FORWARD scope) | `10.<gg>.2.0/24` (e.g. `10.171.2.0/24`) | `fd<gg>:<gggg>:<gggggg>:0200::/64` |
| **strongSwan `pools` range**  | `10.<gg>.2.128/25`    | `fd<gg>:<gggg>:<gggggg>:0200::1000/116`          |
| **Reserved** (static / future infra) | `.1–.127`      | `::1–::fff`                                      |

**IPv6 is always `/64`** — this is the protocol norm; SLAAC, privacy addresses (RFC 4941), and every IPv6 neighbour-discovery mechanism assume a 64-bit interface identifier. The project-wide ULA scheme in `core-infrastructure` already uses `/64` for every subnet; the VPN "subnet" is no exception. strongSwan itself does not do SLAAC on the virtual IPs it hands out (it's IKE CHILD_SA addressing, not an Ethernet-style link), but we still use `/64` as the subnet identity so that any routing, NSG, or future UDR references are consistent with the rest of the landing zone.

The narrower **`pools`** range (`::1000/116` for IPv6, `.128/25` for IPv4) is purely a convenience:

- Memorable client addresses in logs.
- A clean gap for any future static / reserved assignments (e.g. if we ever give the VM its own address on this virtual link, or pin a specific client to a specific address).
- `/116` gives 4096 IPv6 addresses — vastly more than we'd ever use, but trivially small vs. the full `/64`.

The iptables/ip6tables FORWARD and MASQUERADE rules are scoped to the **full subnet** (`10.<gg>.2.0/24`, `fd…:0200::/64`) so that static assignments inside the same subnet would Just Work without rule changes.

**Alternatives considered:**

- *A real Azure VNet for clients* (requiring a new `a-infrastructure/03-initialize-VpnVnet.ps1`) — Rejected after investigation: strongSwan road-warrior P2S does not need one. The pool is purely an IPsec construct; Azure doesn't see or route it.
- *Use `/112` or other non-/64 IPv6 sizing for the subnet itself* — Rejected: violates IPv6 convention, fragments the ULA allocation scheme, gains nothing (address scarcity does not exist at ULA scale).
- *Hand `pools` the full `/64` and `/24`* — Works, but makes it awkward to later carve out static / infrastructure addresses inside the same subnet without reconfiguring strongSwan.
- *Carve from inside the hub VNet `/64`* — Works, but blurs the boundary between the hub and the VPN pool and makes a future workload-subnet UDR harder to target.

**Rationale:** Matches the project-wide ULA `/64`-per-subnet scheme, keeps strongSwan's allocation range small and readable, and leaves room for future static assignments inside the same subnet without rework. Confirmed via the strongSwan swanctl documentation: `pools` + MASQUERADE/forward is the entire story for P2S.

### D11. Three scripts with independent lifecycles, numeric ordering preserved

**Chosen:** Split the VPN capability into three PowerShell scripts:

- `b-shared/03-Deploy-VpnIdentity.ps1` — creates UAMI + grants Key Vault access policy.
- `b-shared/05-Deploy-Certificate.ps1` — local cert generation + Key Vault upload.
- `b-shared/06-Deploy-StrongSwanVm.ps1` — Azure resources (NIC, NSG rules, VM, cloud-init) that consume the UAMI from `03` and the secrets uploaded by `05`.

Run order for a fresh environment becomes: `01-Deploy-AzureMonitor.ps1` → `02-Deploy-KeyVault.ps1` → **`03-Deploy-VpnIdentity.ps1`** → `04-Deploy-GatewaySubnet.ps1` → **`05-Deploy-Certificate.ps1`** → **`06-Deploy-StrongSwanVm.ps1`**.

**Alternatives considered:**

- *One combined script* — Rejected: certs, identities, and VMs have different lifecycles. Rebuilding the VM must not invalidate client certs or identity permissions; rotating certs must not require VM rebuild. Splitting also lets `05` run on any operator machine without Azure compute creation rights.
- *Two scripts (fold UAMI creation into the VM script)* — Rejected: this is what we tried first. Creating the UAMI at VM-deploy time reintroduces a propagation race (permissions are granted right before cloud-init logs in). Separating the identity step lets the access-policy write settle long before the VM boots.
- *Four scripts (separate upload step)* — Rejected: cert generation and upload are always paired for this MVP; re-running `05` is already idempotent, so there's nothing to gain by splitting them.

**Rationale:** Clear separation of concerns, matches the project's migration-style deploy, eliminates identity-propagation races, and leaves room for a future `07-Deploy-StrongSwanClient.ps1` that issues additional client certs without touching the VM.

### D12. Server cert SANs known ahead of VM creation

**Chosen:** The server cert is generated by `05` **before** the VM exists. This is only possible because every public FQDN on the VM is deterministic from parameters the operator already knows:

- Public IPv6 DNS: `strongswan-<OrgId>-<env>.<location>.cloudapp.azure.com` (from `$ServerDnsLabel`)
- Public IPv4 DNS (if `-AddPublicIpv4`): `strongswan-<OrgId>-<env>-ipv4.<location>.cloudapp.azure.com`

`05` accepts the same `-OrgId`, `-Environment`, `-Location`, and `-AddPublicIpv4` parameters as `06` (sharing env-var fallbacks), computes the FQDNs, and emits them as `subjectAltName` DNS entries on the server cert. If the operator changes any of these parameters between running `05` and `06`, the VM's actual hostname won't match the cert SAN and IKEv2 clients will reject the server — this is documented in `.NOTES` on both scripts.

**Alternatives considered:**

- *Issue the cert after the VM's public IP exists* — Forces `05` to run after `06`, requires a reconfiguration step on the VM to pick up the new cert, and makes the script order inconsistent with its numeric prefix.
- *Use IP-based SANs instead of DNS* — Rejected: the public IPv6 is static but the public IPv4 is also static only because we specify `--allocation-method static`; pinning to DNS labels is more portable and matches how Windows/macOS/iOS native clients are configured.

**Rationale:** Determinism of the deployment scheme already in place lets us issue a cert before compute exists, which is what makes splitting `04` from `05` cleanly viable.

### D6. IP forwarding: enable at both Azure NIC level and OS level

**Chosen:**

- Azure NIC: `az network nic update --ids ... --ip-forwarding true` after NIC creation (Azure drops forwarded packets without this flag regardless of OS settings).
- OS: cloud-init writes `/etc/sysctl.d/99-strongswan.conf` with `net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`, `net.ipv6.conf.default.forwarding=1`, and runs `sysctl --system`.

**Rationale:** Both layers are required; skipping either silently breaks forwarding. The Azure-level flag is the one that's most commonly forgotten.

### D7. NAT / forwarding rules via `iptables` + `ip6tables`, not `ufw`

**Chosen:** The cloud-init installs `iptables-persistent` and writes explicit MASQUERADE + FORWARD rules for the VPN VIP pool. UFW is only used for ingress (SSH, UDP 500, UDP 4500, ESP); NAT tables are not managed by UFW.

- IPv4: `iptables -t nat -A POSTROUTING -s <ipv4-pool> -o eth0 -j MASQUERADE` + FORWARD accept both ways for the pool.
- IPv6: `ip6tables -A FORWARD` accept both ways for the pool. (No MASQUERADE; the ULA is routable inside the VNet via peering.)

**Alternatives considered:**

- *`ufw` `before.rules` edits* — Works but is harder to read and validate in review.
- *nftables* — The strongSwan docs are still largely iptables-centric; nftables would add translation burden without benefit.

**Rationale:** Explicit is better than magic for security-critical NAT rules; `iptables-persistent` survives reboots.

### D8. NSG rules added are named, idempotent, and scoped to UDP 500/4500 only

**Chosen:** Add two rules to the existing `nsg-llm-gateway-<env>-001`:

- `AllowIKE` — priority 2100, UDP, destination port 500, source `*`.
- `AllowIPsecNatT` — priority 2101, UDP, destination port 4500, source `*`.

Both are created with `az network nsg rule create`, preceded by `az network nsg rule show` to skip if already present (idempotency, matching the pattern in `04-Deploy-GatewaySubnet.ps1`).

**Rationale:** ESP-over-UDP-4500 is what every modern IKEv2 client uses behind NAT; pure ESP (protocol 50) would require clients with a public IP and is blocked by most home routers anyway. Restricting the source to `*` is acceptable for a road-warrior VPN; tightening can happen via a separate NSG change later.

### D9. Parameters — remove Leshan leftovers, add VPN-specific ones

Parameters on `06-Deploy-StrongSwanVm.ps1`:

| Parameter               | Env var fallback              | Default              | Purpose                                |
|-------------------------|-------------------------------|----------------------|----------------------------------------|
| `-VpnUsername`          | `DEPLOY_VPN_USERNAME`         | `vpnuser`            | EAP-MSCHAPv2 username                  |
| `-VpnUserPassword`      | `DEPLOY_VPN_USER_PASSWORD`    | (required)           | EAP-MSCHAPv2 password                  |
| `-VpnVnetId`            | `DEPLOY_VPN_VNET_ID`          | `02`                 | Virtual VNet ID for client pool        |
| `-UlaGlobalId`          | `DEPLOY_GLOBAL_ID`            | SHA256 of sub id     | ULA prefix (same as script 04)         |
| `-ServerDnsLabel`       | `DEPLOY_VPN_DNS_LABEL`        | `strongswan-<OrgId>-<env>` | Public IP DNS label              |

Parameters on `05-Deploy-Certificate.ps1`:

| Parameter               | Env var fallback              | Default              | Purpose                                |
|-------------------------|-------------------------------|----------------------|----------------------------------------|
| `-Purpose`              | `DEPLOY_PURPOSE`              | `LLM`                | Shared Key Vault naming                |
| `-Environment`          | `DEPLOY_ENVIRONMENT`          | `Dev`                | Shared Key Vault naming / secret suffix |
| `-OrgId`                | `DEPLOY_ORGID`                | derived from sub id  | Unique naming                           |
| `-Location`             | `DEPLOY_LOCATION`             | `australiaeast`      | FQDN domain component                   |
| `-Instance`             | `DEPLOY_INSTANCE`             | `001`                | Key Vault resource naming               |
| `-ServerDnsLabel`       | `DEPLOY_VPN_DNS_LABEL`        | `strongswan-<OrgId>-<env>` | SANs on server cert              |
| `-AddPublicIpv4`        | `DEPLOY_ADD_IPV4`             | `$true`              | Whether to include IPv4 FQDN in SANs    |
| `-TempPath`             | `DEPLOY_TEMP_PATH`            | `<repo>/temp`        | Local output directory for generated material |

Removed from both scripts: `-WebPassword` / `DEPLOY_WEB_PASSWORD`.

Kept on `06` (unchanged from the Leshan script): `-Purpose`, `-Environment`, `-OrgId`, `-Instance`, `-VmSize`, `-AdminUsername`, `-PrivateIpSuffix`, `-ShutdownUtc`, `-ShutdownEmail`, `-AddPublicIpv4`.

Parameters on `03-Deploy-VpnIdentity.ps1`:

| Parameter               | Env var fallback              | Default              | Purpose                                |
|-------------------------|-------------------------------|----------------------|----------------------------------------|
| `-Purpose`              | `DEPLOY_PURPOSE`              | `LLM`                | Shared naming                          |
| `-Environment`          | `DEPLOY_ENVIRONMENT`          | `Dev`                | Shared naming                          |
| `-OrgId`                | `DEPLOY_ORGID`                | derived from sub id  | Unique naming                          |
| `-Location`             | `DEPLOY_LOCATION`             | `australiaeast`      | UAMI region                            |
| `-Instance`             | `DEPLOY_INSTANCE`             | `001`                | UAMI instance suffix                   |

### D10. cloud-init placeholders

The PowerShell script substitutes these tokens into a copy of `strongswan-cloud-init.txt` written to `b-shared/temp/strongswan-cloud-init.txt~`:

| Token                     | Substituted value                                  |
|---------------------------|----------------------------------------------------|
| `#INIT_VPN_USERNAME#`     | `$VpnUsername`                                     |
| `#INIT_VPN_PASSWORD#`     | `$VpnUserPassword`                                 |
| `#INIT_VPN_SUBNET_IPV4#`  | VPN IPv4 subnet (e.g. `10.171.2.0/24`) — used for iptables NAT/FORWARD scope |
| `#INIT_VPN_SUBNET_IPV6#`  | VPN IPv6 `/64` subnet — used for ip6tables FORWARD scope                   |
| `#INIT_VIP_POOL_IPV4#`    | strongSwan IPv4 allocation range (e.g. `10.171.2.128/25`)                  |
| `#INIT_VIP_POOL_IPV6#`    | strongSwan IPv6 allocation range (e.g. `fd…:0200::1000/116`)               |
| `#INIT_SERVER_FQDNS#`     | Comma-separated list of PIP FQDNs (IPv6, optional IPv4) |
| `#INIT_KEY_VAULT_NAME#`   | Key Vault name to fetch CA / server cert / server key from |
| `#INIT_CA_SECRET_NAME#`   | `strongswan-<env>-ca-cert`                                                 |
| `#INIT_SERVER_CERT_SECRET_NAME#` | `strongswan-<env>-server-cert`                                      |
| `#INIT_SERVER_KEY_SECRET_NAME#`  | `strongswan-<env>-server-key`                                       |
| `#INIT_ADMIN_USER#`       | `$AdminUsername`                                                           |
| `#INIT_UAMI_CLIENT_ID#`   | `clientId` of the UAMI provisioned by `03-Deploy-VpnIdentity.ps1`          |

All Leshan-era tokens (`#INIT_HOST_NAMES#`, `#INIT_PASSWORD_INPUT#`) are removed.

## Risks / Trade-offs

- **[Cloud-init failures are silent until polled]** → The PowerShell script waits for cloud-init (`cloud-init status --wait`) via `az vm run-command` and fails loudly if the final status is not `done`. Logs from `/var/log/cloud-init-output.log` are fetched on failure.
- **[Managed-identity access-policy propagation]** → Access-policy writes in access-policy mode typically become effective immediately, but Azure Resource Manager cache propagation can still take a few seconds. Because the UAMI is created and granted access by `03-Deploy-VpnIdentity.ps1` — which runs minutes before the VM boots — this is not a practical concern. Cloud-init nonetheless retains a retry loop around `az login --identity` and `az keyvault secret download` (cap ~2 minutes) to cover IMDS / guest-OS readiness on first boot.
- **[Local private keys in `./temp/`]** → Plaintext keys live on the operator machine. Mitigation: `./temp/` is gitignored, and the CA key never leaves the operator machine (unlike the server key which is uploaded to Key Vault so cloud-init can install it). Operators should treat `./temp/` with the same hygiene as `~/.ssh/`.
- **[Parameter drift between `05` and `06`]** → If `-OrgId`, `-Environment`, `-Location`, or `-AddPublicIpv4` differ between the two runs, the server cert SANs won't match the VM's FQDN and clients will reject the connection. Mitigated by the shared env-var fallback pattern (operators export once, both scripts see the same values) and by documentation in `.NOTES` on both scripts.
- **[Public IKE/NAT-T ports exposed to the whole internet]** → Accepted for MVP (standard road-warrior posture). EAP-MSCHAPv2 is protected by server cert + IKEv2 mutual auth, so it's not MSCHAPv2-over-the-wire; rate-limiting and fail2ban can be added in a later change.
- **[Single VM = single point of failure]** → Accepted; HA is explicitly out of scope. Auto-shutdown continues to apply (this is a dev-tier component).
- **[EAP-MSCHAPv2 password in environment variable / script parameter]** → Documented in the script `.NOTES`; operator should use a secure env var source (e.g. 1Password CLI, Key Vault reference) rather than plaintext shell history.
- **[IPv6 MASQUERADE omitted]** → Deliberate: IPv6 ULA addresses are routable via VNet peering; NAT66 would break that. Trade-off: if clients try to reach public IPv6 destinations through the tunnel, those will fail unless IPv6 egress is explicitly configured later.
- **[Cert lifetimes are long (CA 10yr, server 5yr, client 1yr)]** → No rotation story in this change. Tracked as a future improvement. Rotating the server cert requires re-running `05` (with `./temp/strongswan-server.*` deleted), re-uploading, and rebooting the VM or `swanctl --load-all`.

## Migration Plan

This change rewrites the broken Leshan-copy placeholder into three new scripts. There is no in-place upgrade path — it is a first working deployment.

1. Merge the proposal + design + specs + tasks.
2. Operator rebuilds the devcontainer (picks up `openssl` + `strongswan-pki`).
3. Operator runs, in order: `01-Deploy-AzureMonitor.ps1`, `02-Deploy-KeyVault.ps1`, **`03-Deploy-VpnIdentity.ps1`**, `04-Deploy-GatewaySubnet.ps1`, **`05-Deploy-Certificate.ps1`**, **`06-Deploy-StrongSwanVm.ps1`**.
4. Client provisioning (manual for MVP):
   - Fetch `strongswan-<env>-ca-cert` and `strongswan-<env>-client-001-p12` from Key Vault.
   - Import on client OS (Windows: PowerShell `Add-VpnConnection` + `Import-PfxCertificate`; macOS: double-click `.p12`; Linux: `strongswan` or NetworkManager).
5. Rollback:
   - To re-issue all certs: delete `./temp/` locally, delete the Key Vault secrets (or soft-delete + purge), re-run `05`, then re-run `06` (the VM will pick up the new server cert on next reboot or via a manual `swanctl --load-all`).
   - To tear down the VM only: delete the VM, NIC, public IPs, and remove the two NSG rules; leave `05`'s Key Vault secrets and `03`'s UAMI in place.
   - Full teardown: `util/Remove-Rg.ps1 -Environment <env>` removes the shared RG; the Key Vault soft-delete retains secrets for the default retention window unless purged.

## Open Questions

- **Should EAP credentials also be stored hashed on the VM rather than plaintext in `swanctl.conf`?** strongSwan supports `secret = ...` with `$5$`/`$6$` crypt hashes; for MVP we use plaintext in a root-only file. Review before Prod use.
- **Should EAP credentials be pushed to Key Vault?** Currently they are not (they are passed as script parameters to `06`). Storing them in Key Vault and having cloud-init fetch them would let `06` be re-run without re-supplying the password, at the cost of a secondary secret. Deferred to a rotation-focused follow-up.
- **Do we need a public IPv4 at all?** README calls IPv6 the primary; native IKEv2 clients on residential IPv4-only networks will need the IPv4 endpoint. Default `-AddPublicIpv4 = $true` is retained for now. Note that `-AddPublicIpv4` must be identical when running `05` and `06` (else server cert SANs won't match the VM's IPv4 FQDN).
- **Should Key Vault secret content-types be set (`application/x-pem-file`, `application/x-pkcs12`)?** Nice-to-have; proposed to set, but not a blocker.
- **Should the CA private key also be uploaded to Key Vault?** For MVP, the CA private key stays in `./temp/` so that `05` can re-sign new client certs on re-run. A future change could optionally upload (and encrypt-with-a-different-KV-key) the CA key for recovery; deliberately not done now to keep the CA key's attack surface small.
