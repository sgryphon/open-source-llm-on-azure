## 1. Repo hygiene and tooling

- [x] 1.1 Add `temp/` (repo-root) to `.gitignore`, and verify `git status` ignores newly-created files under temp paths.
- [x] 1.2 Update the devcontainer (`.devcontainer/Dockerfile` or feature config) to install `openssl` and `strongswan-pki`; rebuild and verify `which pki` + `which openssl` both succeed in a fresh container.

## 2. Shared cert address / FQDN helper logic

- [x] 2.1 Decide on (and document in both scripts' `.NOTES`) the exact formula for `$ServerDnsLabel` and the IPv4 variant so that `05` and `06` compute identical FQDNs from the same inputs.
- [x] 2.2 Write a reusable PowerShell snippet (can be duplicated; do not create a module) that derives the IPv6 / IPv4 PIP FQDNs from `-OrgId`, `-Environment`, `-Location`, and `-AddPublicIpv4`.
- [x] 2.3 Write a reusable snippet that derives the VPN client subnet + pool ranges from `-UlaGlobalId` and `-VpnVnetId` (IPv6 `/64` subnet + `/116` pool at `::1000`; IPv4 `/24` subnet + upper-half `/25` pool).

## 3. `b-shared/03-Deploy-VpnIdentity.ps1` — UAMI + Key Vault access policy

- [x] 3.1 Create `b-shared/03-Deploy-VpnIdentity.ps1` with `#!/usr/bin/env pwsh`, `[CmdletBinding()]`, `$ErrorActionPreference='Stop'`, and comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`, `.EXAMPLE`).
- [x] 3.2 Add the parameter block with env-var fallbacks per the spec table: `-Purpose`, `-Environment`, `-OrgId`, `-Location`, `-Instance`.
- [x] 3.3 Derive the UAMI name (`id-<purpose>-strongswan-<env>-<instance>`), shared RG name, and Key Vault name at the top with `Write-Verbose` traces.
- [x] 3.4 Verify Key Vault exists and is in access-policy mode (`az keyvault show --query properties.enableRbacAuthorization`); fail fast if either fails, referencing `02-Deploy-KeyVault.ps1`.
- [x] 3.5 `az identity show` pre-check; if absent, `az identity create`. Capture `id` (resource ID), `principalId`, and `clientId` in script variables.
- [x] 3.6 `az keyvault set-policy --object-id <principalId> --secret-permissions get list` (idempotent — set-policy replaces the entry).
- [x] 3.7 `Write-Verbose` the UAMI resource ID and client ID on success for the operator to capture.

## 4. Rename existing GatewaySubnet script

- [x] 4.1 `git mv b-shared/03-Deploy-GatewaySubnet.ps1 b-shared/04-Deploy-GatewaySubnet.ps1` to preserve history. Content unchanged.
- [x] 4.2 Update any `.NOTES` / `.EXAMPLE` / cross-reference inside the renamed script that refers to itself by the old number.

## 5. `b-shared/05-Deploy-Certificate.ps1` — scaffold (renamed from planned `04-…`)

- [x] 5.1 Create `b-shared/05-Deploy-Certificate.ps1` with `#!/usr/bin/env pwsh`, `[CmdletBinding()]`, `$ErrorActionPreference='Stop'`, and comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`, `.EXAMPLE`).
- [x] 5.2 Add the parameter block with env-var fallbacks and defaults per the spec table: `-Purpose`, `-Environment`, `-OrgId`, `-Location`, `-Instance`, `-ServerDnsLabel`, `-AddPublicIpv4`, `-TempPath`.
- [x] 5.3 Compute derived names (Key Vault name matching `02-Deploy-KeyVault.ps1`, secret name prefix `strongswan-<env>-`, server cert FQDN list) at the top of the script, with `Write-Verbose` traces.
- [x] 5.4 Ensure `$TempPath` exists (`New-Item -ItemType Directory -Force`) and resolve to an absolute path.

## 6. `05-Deploy-Certificate.ps1` — CA generation (idempotent)

- [x] 6.1 Guard: if both `$TempPath/strongswan-ca.key` and `$TempPath/strongswan-ca.pem` exist, `Write-Verbose` "CA already present, skipping" and proceed.
- [x] 6.2 Generate CA private key (RSA 4096) via `pki --gen --type rsa --size 4096 --outform pem` into a temp path, then move to `strongswan-ca.key` (avoid partial-file state on interrupt).
- [x] 6.3 Issue self-signed CA cert via `pki --self --ca --in strongswan-ca.key --dn "CN=strongSwan <OrgId> <Env> CA"` with a 10-year `--lifetime`; write to `strongswan-ca.pem`.
- [x] 6.4 Verify the generated CA cert (`pki --print --in strongswan-ca.pem`) in verbose output; fail the script if verification doesn't return a matching CN.

## 7. `05-Deploy-Certificate.ps1` — server cert generation (idempotent)

- [x] 7.1 Guard: if both `$TempPath/strongswan-server.key` and `$TempPath/strongswan-server.pem` exist, skip.
- [x] 7.2 Generate server private key (RSA 4096) into `strongswan-server.key`.
- [x] 7.3 Build the server cert SAN list from the FQDN helper (include IPv4 FQDN only when `-AddPublicIpv4`). Include the `serverAuth` extended key usage.
- [x] 7.4 Issue server cert signed by the CA via `pki --issue --cacert strongswan-ca.pem --cakey strongswan-ca.key --in <csr or pub>` with `--san` entries and a 5-year lifetime; write to `strongswan-server.pem`.
- [x] 7.5 Verify: `pki --print --in strongswan-server.pem` output includes every expected SAN.

## 8. `05-Deploy-Certificate.ps1` — initial client cert + PKCS#12 (idempotent)

- [x] 8.1 Guard: if all of `strongswan-client-001.key`, `strongswan-client-001.pem`, `strongswan-client-001.p12`, and `strongswan-client-001-p12-password.txt` exist, skip.
- [x] 8.2 Generate PKCS#12 password with `openssl rand -base64 24` and write to `strongswan-client-001-p12-password.txt` (mode 0600 where filesystem supports it) if the file does not already exist.
- [x] 8.3 Generate client private key (RSA 4096) into `strongswan-client-001.key`.
- [x] 8.4 Issue client cert signed by the CA with `CN=client-<OrgId>-<Env>-001`, `clientAuth` EKU, 1-year lifetime; write to `strongswan-client-001.pem`.
- [x] 8.5 Package PKCS#12 via `openssl pkcs12 -export -inkey ... -in ... -certfile strongswan-ca.pem -out strongswan-client-001.p12 -passout file:strongswan-client-001-p12-password.txt`.

## 9. `05-Deploy-Certificate.ps1` — Key Vault upload (idempotent)

- [x] 9.1 Look up the Key Vault by derived name (`az keyvault show`); fail with a clear error if absent ("Run `02-Deploy-KeyVault.ps1` first").
- [x] 9.2 For each of the five secrets (`*-ca-cert`, `*-server-cert`, `*-server-key`, `*-client-001-p12`, `*-client-001-p12-password`):
  - [x] 9.2.1 `az keyvault secret show` pre-check; if a value exists, `Write-Verbose` "Skipping <name>" and continue.
  - [x] 9.2.2 Otherwise `az keyvault secret set` with the correct `--content-type` (`application/x-pem-file` for PEMs, `application/x-pkcs12` for the bundle, none for the password). PEMs uploaded as `--file`; PKCS#12 base64-encoded via `--value`.
- [x] 9.3 Confirm via `az keyvault secret list` in verbose output that all five secret names are present.
- [x] 9.4 Explicitly do NOT upload `strongswan-ca.key` under any secret name (add a negative assertion as a comment referencing the spec).

## 10. Cloud-init template rewrite (`b-shared/data/strongswan-cloud-init.txt`)

- [x] 10.1 Replace the entire file contents. Remove Caddy apt source + key, Java JRE, Leshan wget, iotadmin references, `#INIT_HOST_NAMES#`, `#INIT_PASSWORD_INPUT#`.
- [x] 10.2 Declare packages: `strongswan`, `strongswan-swanctl`, `libcharon-extra-plugins`, `libstrongswan-extra-plugins`, `iptables-persistent`, `azure-cli`, `ufw`.
- [x] 10.3 Write `/etc/sysctl.d/99-strongswan.conf` with `net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`, `net.ipv6.conf.default.forwarding=1`; apply via `sysctl --system`.
- [x] 10.4 First `runcmd` step: retry loop (cap 120 s) running `az login --identity --username "$UAMI_CLIENT_ID"` (where `UAMI_CLIENT_ID` comes from `#INIT_UAMI_CLIENT_ID#`) and downloading the three Key Vault secrets (`#INIT_CA_SECRET_NAME#` → `/etc/swanctl/x509ca/ca.pem`, `#INIT_SERVER_CERT_SECRET_NAME#` → `/etc/swanctl/x509/server.pem`, `#INIT_SERVER_KEY_SECRET_NAME#` → `/etc/swanctl/private/server.key`). Set `chmod 600` on the key, `chmod 644` on the certs.
- [x] 10.5 Write `/etc/swanctl/swanctl.conf` via `write_files` with one IKEv2 road-warrior connection that (a) local: pubkey using the server cert; (b) remote-1: EAP-MSCHAPv2 using `#INIT_VPN_USERNAME#` / `#INIT_VPN_PASSWORD#`; (c) remote-2: pubkey against the CA. Include `pools` declaring `#INIT_VIP_POOL_IPV4#` and `#INIT_VIP_POOL_IPV6#`; include DNS push (`168.63.129.16`, plus an IPv6 DNS if we pick one).
- [x] 10.6 Write `/etc/swanctl/conf.d/secrets.conf` containing the EAP credential in strongSwan syntax (plaintext; root-read-only — `owner: root:root`, `permissions: '0600'`).
- [x] 10.7 `runcmd`: configure iptables + ip6tables rules (IPv4 MASQUERADE for `#INIT_VPN_SUBNET_IPV4#` out `eth0`; FORWARD accept both directions; IPv6 FORWARD accept both directions for `#INIT_VPN_SUBNET_IPV6#`, no NAT66); persist via `netfilter-persistent save`.
- [x] 10.8 `runcmd`: `ufw allow 22/tcp`, `ufw allow 500/udp`, `ufw allow 4500/udp`, `ufw --force enable`.
- [x] 10.9 `runcmd`: `systemctl enable --now strongswan`; `swanctl --load-all`; emit `swanctl --list-conns` to the cloud-init log for debuggability.
- [x] 10.10 Confirm (by grep) that the final template contains none of: `caddy`, `default-jre`, `leshan`, `#INIT_HOST_NAMES#`, `#INIT_PASSWORD_INPUT#`, `basicauth`.

## 11. `b-shared/06-Deploy-StrongSwanVm.ps1` — scaffold

- [x] 11.1 Update `b-shared/06-Deploy-StrongSwanVm.ps1` with the standard header (`#!/usr/bin/env pwsh`, `[CmdletBinding()]`, `$ErrorActionPreference='Stop'`, comment-based help describing strongSwan + UAMI binding, NOT Leshan).
- [x] 11.2 Add the parameter block with env-var fallbacks per the spec table (`-VpnUsername`, `-VpnUserPassword` (required), `-VpnVnetId`, `-UlaGlobalId`, `-ServerDnsLabel`, plus the kept parameters from the old script). Remove `-WebPassword`.
- [x] 11.3 Validate `-VpnUserPassword` is non-empty (throw with clear message and env-var hint).
- [x] 11.4 Resolve the gateway RG, VNet, gateway subnet, and gateway NSG via `az ... show` (fail early if any are missing with references to the prerequisite scripts). Drop the broken `$Region`/`$VnetId`/`$SubnetId`/`$prefixByte` arithmetic entirely.
- [x] 11.5 Resolve the UAMI via `az identity show`; capture its resource ID and `clientId`. Fail with a clear error ("Run `03-Deploy-VpnIdentity.ps1` first") if absent.
- [x] 11.6 Compute the VPN subnet + pool ranges (IPv4 and IPv6) using the shared helper from task 2.3.
- [x] 11.7 Compute the public FQDNs using the helper from task 2.2.
- [x] 11.8 Verify Key Vault secrets exist (`az keyvault secret show` for each of the three needed by cloud-init); fail with a clear error if absent ("Run `05-Deploy-Certificate.ps1` first").
- [x] 11.9 Build the tag dictionary matching `04-Deploy-GatewaySubnet.ps1`'s style.

## 12. `06-Deploy-StrongSwanVm.ps1` — NSG rules (idempotent)

- [x] 12.1 For `AllowIKE` (priority 2100, UDP, port 500): `az network nsg rule show` pre-check; create if absent with the exact parameters from the spec.
- [x] 12.2 For `AllowIPsecNatT` (priority 2101, UDP, port 4500): same pre-check + create pattern.
- [x] 12.3 Verify both rules via `az network nsg rule list` in verbose output.

## 13. `06-Deploy-StrongSwanVm.ps1` — public IPs + NIC (idempotent)

- [x] 13.1 Create the IPv6 public IP (Standard SKU, static, IPv6) idempotently (`pip show` pre-check, or catch "already exists").
- [x] 13.2 Create the IPv4 public IP (Standard SKU, static, IPv4) idempotently when `-AddPublicIpv4`.
- [x] 13.3 Create the NIC with a primary IPv4 ip-config and a secondary IPv6 ip-config attached to the gateway subnet and the public IPs (idempotent; skip if NIC exists).
- [x] 13.4 `az network nic update --ip-forwarding true` on the NIC.

## 14. `06-Deploy-StrongSwanVm.ps1` — render cloud-init

- [x] 14.1 Ensure `b-shared/temp/` exists.
- [x] 14.2 Load `b-shared/data/strongswan-cloud-init.txt` and substitute every required token (per the spec): `#INIT_VPN_USERNAME#`, `#INIT_VPN_PASSWORD#`, `#INIT_VPN_SUBNET_IPV4#`, `#INIT_VPN_SUBNET_IPV6#`, `#INIT_VIP_POOL_IPV4#`, `#INIT_VIP_POOL_IPV6#`, `#INIT_SERVER_FQDNS#`, `#INIT_KEY_VAULT_NAME#`, `#INIT_CA_SECRET_NAME#`, `#INIT_SERVER_CERT_SECRET_NAME#`, `#INIT_SERVER_KEY_SECRET_NAME#`, `#INIT_ADMIN_USER#`, `#INIT_UAMI_CLIENT_ID#`.
- [x] 14.3 Write the rendered file to `b-shared/temp/strongswan-cloud-init.txt~`.
- [x] 14.4 Post-render assertion: grep the rendered file for any remaining `#INIT_[A-Z_]+#`; if found, throw.

## 15. `06-Deploy-StrongSwanVm.ps1` — VM create with UAMI binding

- [x] 15.1 `az vm show` pre-check; if the VM exists, skip `vm create`.
- [x] 15.2 `az vm create` with: `--image UbuntuLTS`, `--size $VmSize`, `--nics $nicName`, `--admin-username $AdminUsername`, `--generate-ssh-keys`, `--assign-identity $uamiResourceId`, `--custom-data <rendered cloud-init>`, and tags. No `--role` / `--scope` flags — all identity permissions are already in place from `03`.
- [x] 15.3 On the re-run branch (VM already exists), use `az vm identity assign --identities $uamiResourceId` to ensure the UAMI is attached (idempotent — Azure is a no-op if already bound).
- [x] 15.4 Do NOT create any role assignment; do NOT set or modify any Key Vault access policy. The script explicitly does not assume `Microsoft.Authorization/roleAssignments/write` permissions on the calling identity.
- [x] 15.5 Apply the auto-shutdown block (same pattern as the placeholder; `$ShutdownUtc`, optional `$ShutdownEmail`).

## 16. `06-Deploy-StrongSwanVm.ps1` — post-deploy verification + operator output

- [x] 16.1 Poll cloud-init via `az vm run-command invoke ... --scripts "cloud-init status --wait"`; fail with `/var/log/cloud-init-output.log` fetched via another run-command if status is not `done`.
- [x] 16.2 Print VM FQDNs, public IPs, the Key Vault name, and the five VPN secret names to stdout (replace the trailing Leshan `ssh ...` comment from the old script).
- [x] 16.3 Print a one-liner example for downloading the client `.p12` and password from Key Vault.

## 17. Documentation + final verification

- [x] 17.1 Update `README.md` run-order section (if present) to reference `03-Deploy-VpnIdentity.ps1`, `04-Deploy-GatewaySubnet.ps1`, `05-Deploy-Certificate.ps1`, then `06-Deploy-StrongSwanVm.ps1`; remove any reference to `-WebPassword` / `DEPLOY_WEB_PASSWORD`. Update `AGENTS.md` to reference `04-Deploy-GatewaySubnet.ps1` where it previously referenced `03-…`.
- [ ] 17.2 Run all four scripts (`03`, `04`, `05`, `06`) end-to-end against a Dev subscription (`$VerbosePreference = 'Continue'`); confirm clean first run with a Contributor-only principal (no `roleAssignments/write`).
- [ ] 17.3 Re-run all four scripts; confirm no errors and no duplicate resources (UAMI, access-policy entry, VM, NIC, PIPs, NSG rules, Key Vault secret versions).
- [ ] 17.4 Confirm `az role assignment list --all --assignee <uami-principalId>` returns empty (the capability creates zero role assignments).
- [ ] 17.5 Import the client `.p12` on a development machine, connect via native IKEv2 with **EAP-MSCHAPv2** (username/password), and confirm IPv4 + IPv6 reachability to a VNet resource.
- [ ] 17.6 Repeat the connection test using **client-cert** auth; confirm IPv4 + IPv6 reachability.
- [ ] 17.7 Tear down via `util/Remove-Rg.ps1` and confirm a fresh re-deploy works (exercises the Key Vault soft-delete path for secrets and UAMI re-creation).
