## 1. Repo hygiene and tooling

- [x] 1.1 Add `temp/` (repo-root) to `.gitignore`, and verify `git status` ignores newly-created files under temp paths.
- [x] 1.2 Update the devcontainer (`.devcontainer/Dockerfile` or feature config) to install `openssl` and `strongswan-pki`; rebuild and verify `which pki` + `which openssl` both succeed in a fresh container.

## 2. Shared cert address / FQDN helper logic

- [x] 2.1 Decide on (and document in both scripts' `.NOTES`) the exact formula for `$ServerDnsLabel` and the IPv4 variant so that `04` and `05` compute identical FQDNs from the same inputs.
- [x] 2.2 Write a reusable PowerShell snippet (can be duplicated; do not create a module) that derives the IPv6 / IPv4 PIP FQDNs from `-OrgId`, `-Environment`, `-Location`, and `-AddPublicIpv4`.
- [x] 2.3 Write a reusable snippet that derives the VPN client subnet + pool ranges from `-UlaGlobalId` and `-VpnVnetId` (IPv6 `/64` subnet + `/116` pool at `::1000`; IPv4 `/24` subnet + upper-half `/25` pool).

## 3. `b-shared/04-Deploy-Certificate.ps1` — scaffold

- [x] 3.1 Create `b-shared/04-Deploy-Certificate.ps1` with `#!/usr/bin/env pwsh`, `[CmdletBinding()]`, `$ErrorActionPreference='Stop'`, and comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`, `.EXAMPLE`).
- [x] 3.2 Add the parameter block with env-var fallbacks and defaults per the spec table: `-Purpose`, `-Environment`, `-OrgId`, `-Location`, `-Instance`, `-ServerDnsLabel`, `-AddPublicIpv4`, `-TempPath`.
- [x] 3.3 Compute derived names (Key Vault name matching `02-Deploy-KeyVault.ps1`, secret name prefix `strongswan-<env>-`, server cert FQDN list) at the top of the script, with `Write-Verbose` traces.
- [x] 3.4 Ensure `$TempPath` exists (`New-Item -ItemType Directory -Force`) and resolve to an absolute path.

## 4. `04-Deploy-Certificate.ps1` — CA generation (idempotent)

- [x] 4.1 Guard: if both `$TempPath/strongswan-ca.key` and `$TempPath/strongswan-ca.pem` exist, `Write-Verbose` "CA already present, skipping" and proceed.
- [x] 4.2 Generate CA private key (RSA 4096) via `pki --gen --type rsa --size 4096 --outform pem` into a temp path, then move to `strongswan-ca.key` (avoid partial-file state on interrupt).
- [x] 4.3 Issue self-signed CA cert via `pki --self --ca --in strongswan-ca.key --dn "CN=strongSwan <OrgId> <Env> CA"` with a 10-year `--lifetime`; write to `strongswan-ca.pem`.
- [x] 4.4 Verify the generated CA cert (`pki --print --in strongswan-ca.pem`) in verbose output; fail the script if verification doesn't return a matching CN.

## 5. `04-Deploy-Certificate.ps1` — server cert generation (idempotent)

- [x] 5.1 Guard: if both `$TempPath/strongswan-server.key` and `$TempPath/strongswan-server.pem` exist, skip.
- [x] 5.2 Generate server private key (RSA 4096) into `strongswan-server.key`.
- [x] 5.3 Build the server cert SAN list from the FQDN helper (include IPv4 FQDN only when `-AddPublicIpv4`). Include the `serverAuth` extended key usage.
- [x] 5.4 Issue server cert signed by the CA via `pki --issue --cacert strongswan-ca.pem --cakey strongswan-ca.key --in <csr or pub>` with `--san` entries and a 5-year lifetime; write to `strongswan-server.pem`.
- [x] 5.5 Verify: `pki --print --in strongswan-server.pem` output includes every expected SAN.

## 6. `04-Deploy-Certificate.ps1` — initial client cert + PKCS#12 (idempotent)

- [x] 6.1 Guard: if all of `strongswan-client-001.key`, `strongswan-client-001.pem`, `strongswan-client-001.p12`, and `strongswan-client-001-p12-password.txt` exist, skip.
- [x] 6.2 Generate PKCS#12 password with `openssl rand -base64 24` and write to `strongswan-client-001-p12-password.txt` (mode 0600 where filesystem supports it) if the file does not already exist.
- [x] 6.3 Generate client private key (RSA 4096) into `strongswan-client-001.key`.
- [x] 6.4 Issue client cert signed by the CA with `CN=client-<OrgId>-<Env>-001`, `clientAuth` EKU, 1-year lifetime; write to `strongswan-client-001.pem`.
- [x] 6.5 Package PKCS#12 via `openssl pkcs12 -export -inkey ... -in ... -certfile strongswan-ca.pem -out strongswan-client-001.p12 -passout file:strongswan-client-001-p12-password.txt`.

## 7. `04-Deploy-Certificate.ps1` — Key Vault upload (idempotent)

- [x] 7.1 Look up the Key Vault by derived name (`az keyvault show`); fail with a clear error if absent ("Run `02-Deploy-KeyVault.ps1` first").
- [x] 7.2 For each of the five secrets (`*-ca-cert`, `*-server-cert`, `*-server-key`, `*-client-001-p12`, `*-client-001-p12-password`):
  - [x] 7.2.1 `az keyvault secret show` pre-check; if a value exists, `Write-Verbose` "Skipping <name>" and continue.
  - [x] 7.2.2 Otherwise `az keyvault secret set` with the correct `--content-type` (`application/x-pem-file` for PEMs, `application/x-pkcs12` for the bundle, none for the password). PEMs uploaded as `--file`; PKCS#12 base64-encoded via `--value`.
- [x] 7.3 Confirm via `az keyvault secret list` in verbose output that all five secret names are present.
- [x] 7.4 Explicitly do NOT upload `strongswan-ca.key` under any secret name (add a negative assertion as a comment referencing the spec).

## 8. Cloud-init template rewrite (`b-shared/data/strongswan-cloud-init.txt`)

- [x] 8.1 Replace the entire file contents. Remove Caddy apt source + key, Java JRE, Leshan wget, iotadmin references, `#INIT_HOST_NAMES#`, `#INIT_PASSWORD_INPUT#`.
- [x] 8.2 Declare packages: `strongswan`, `strongswan-swanctl`, `libcharon-extra-plugins`, `libstrongswan-extra-plugins`, `iptables-persistent`, `azure-cli`, `ufw`.
- [x] 8.3 Write `/etc/sysctl.d/99-strongswan.conf` with `net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`, `net.ipv6.conf.default.forwarding=1`; apply via `sysctl --system`.
- [x] 8.4 First `runcmd` step: retry loop (cap 120 s) running `az login --identity` and downloading the three Key Vault secrets (`#INIT_CA_SECRET_NAME#` → `/etc/swanctl/x509ca/ca.pem`, `#INIT_SERVER_CERT_SECRET_NAME#` → `/etc/swanctl/x509/server.pem`, `#INIT_SERVER_KEY_SECRET_NAME#` → `/etc/swanctl/private/server.key`). Set `chmod 600` on the key, `chmod 644` on the certs.
- [x] 8.5 Write `/etc/swanctl/swanctl.conf` via `write_files` with one IKEv2 road-warrior connection that (a) local: pubkey using the server cert; (b) remote-1: EAP-MSCHAPv2 using `#INIT_VPN_USERNAME#` / `#INIT_VPN_PASSWORD#`; (c) remote-2: pubkey against the CA. Include `pools` declaring `#INIT_VIP_POOL_IPV4#` and `#INIT_VIP_POOL_IPV6#`; include DNS push (`168.63.129.16`, plus an IPv6 DNS if we pick one).
- [x] 8.6 Write `/etc/swanctl/conf.d/secrets.conf` containing the EAP credential in strongSwan syntax (plaintext; root-read-only — `owner: root:root`, `permissions: '0600'`).
- [x] 8.7 `runcmd`: configure iptables + ip6tables rules (IPv4 MASQUERADE for `#INIT_VPN_SUBNET_IPV4#` out `eth0`; FORWARD accept both directions; IPv6 FORWARD accept both directions for `#INIT_VPN_SUBNET_IPV6#`, no NAT66); persist via `netfilter-persistent save`.
- [x] 8.8 `runcmd`: `ufw allow 22/tcp`, `ufw allow 500/udp`, `ufw allow 4500/udp`, `ufw --force enable`.
- [x] 8.9 `runcmd`: `systemctl enable --now strongswan`; `swanctl --load-all`; emit `swanctl --list-conns` to the cloud-init log for debuggability.
- [x] 8.10 Confirm (by grep) that the final template contains none of: `caddy`, `default-jre`, `leshan`, `#INIT_HOST_NAMES#`, `#INIT_PASSWORD_INPUT#`, `basicauth`.

## 9. `b-shared/05-Deploy-StrongSwanVm.ps1` — scaffold

- [x] 9.1 Update `b-shared/05-Deploy-StrongSwanVm.ps1` with the standard header (`#!/usr/bin/env pwsh`, `[CmdletBinding()]`, `$ErrorActionPreference='Stop'`, comment-based help describing strongSwan, NOT Leshan).
- [x] 9.2 Add the parameter block with env-var fallbacks per the spec table (`-VpnUsername`, `-VpnUserPassword` (required), `-VpnVnetId`, `-UlaGlobalId`, `-ServerDnsLabel`, plus the kept parameters from the old script). Remove `-WebPassword`.
- [x] 9.3 Validate `-VpnUserPassword` is non-empty (throw with clear message and env-var hint).
- [x] 9.4 Resolve the gateway RG, VNet, gateway subnet, and gateway NSG via `az ... show` (fail early if any are missing with references to the prerequisite scripts). Drop the broken `$Region`/`$VnetId`/`$SubnetId`/`$prefixByte` arithmetic entirely.
- [x] 9.5 Compute the VPN subnet + pool ranges (IPv4 and IPv6) using the shared helper from task 2.3.
- [x] 9.6 Compute the public FQDNs using the helper from task 2.2.
- [x] 9.7 Verify Key Vault secrets exist (`az keyvault secret show` for each of the three needed by cloud-init); fail with a clear error if absent ("Run `04-Deploy-Certificate.ps1` first").
- [x] 9.8 Build the tag dictionary matching `03-Deploy-GatewaySubnet.ps1`'s style.

## 10. `05-Deploy-StrongSwanVm.ps1` — NSG rules (idempotent)

- [x] 10.1 For `AllowIKE` (priority 2100, UDP, port 500): `az network nsg rule show` pre-check; create if absent with the exact parameters from the spec.
- [x] 10.2 For `AllowIPsecNatT` (priority 2101, UDP, port 4500): same pre-check + create pattern.
- [x] 10.3 Verify both rules via `az network nsg rule list` in verbose output.

## 11. `05-Deploy-StrongSwanVm.ps1` — public IPs + NIC (idempotent)

- [x] 11.1 Create the IPv6 public IP (Standard SKU, static, IPv6) idempotently (`pip show` pre-check, or catch "already exists").
- [x] 11.2 Create the IPv4 public IP (Standard SKU, static, IPv4) idempotently when `-AddPublicIpv4`.
- [x] 11.3 Create the NIC with a primary IPv4 ip-config and a secondary IPv6 ip-config attached to the gateway subnet and the public IPs (idempotent; skip if NIC exists).
- [x] 11.4 `az network nic update --ip-forwarding true` on the NIC.

## 12. `05-Deploy-StrongSwanVm.ps1` — render cloud-init

- [x] 12.1 Ensure `b-shared/temp/` exists.
- [x] 12.2 Load `b-shared/data/strongswan-cloud-init.txt` and substitute every required token (per the spec): `#INIT_VPN_USERNAME#`, `#INIT_VPN_PASSWORD#`, `#INIT_VPN_SUBNET_IPV4#`, `#INIT_VPN_SUBNET_IPV6#`, `#INIT_VIP_POOL_IPV4#`, `#INIT_VIP_POOL_IPV6#`, `#INIT_SERVER_FQDNS#`, `#INIT_KEY_VAULT_NAME#`, `#INIT_CA_SECRET_NAME#`, `#INIT_SERVER_CERT_SECRET_NAME#`, `#INIT_SERVER_KEY_SECRET_NAME#`, `#INIT_ADMIN_USER#`.
- [x] 12.3 Write the rendered file to `b-shared/temp/strongswan-cloud-init.txt~`.
- [x] 12.4 Post-render assertion: grep the rendered file for any remaining `#INIT_[A-Z_]+#`; if found, throw.

## 13. `05-Deploy-StrongSwanVm.ps1` — VM create + identity + RBAC

- [x] 13.1 `az vm show` pre-check; if the VM exists, skip `vm create`.
- [x] 13.2 `az vm create` with: `--image UbuntuLTS`, `--size $VmSize`, `--nics $nicName`, `--admin-username $AdminUsername`, `--generate-ssh-keys`, `--assign-identity`, `--custom-data <rendered cloud-init>`, and tags.
- [x] 13.3 Capture the VM's system-assigned managed identity principal ID (`az vm identity show` or `vm create` output).
- [x] 13.4 `az role assignment create --role "Key Vault Secrets User" --assignee-object-id <mi-principal-id> --assignee-principal-type ServicePrincipal --scope <key-vault-resource-id>` with an `az role assignment list` pre-check for idempotency.
- [x] 13.5 Apply the auto-shutdown block (same pattern as the placeholder; `$ShutdownUtc`, optional `$ShutdownEmail`).

## 14. `05-Deploy-StrongSwanVm.ps1` — post-deploy verification + operator output

- [x] 14.1 Poll cloud-init via `az vm run-command invoke ... --scripts "cloud-init status --wait"`; fail with `/var/log/cloud-init-output.log` fetched via another run-command if status is not `done`.
- [x] 14.2 Print VM FQDNs, public IPs, the Key Vault name, and the five VPN secret names to stdout (replace the trailing Leshan `ssh ...` comment from the old script).
- [x] 14.3 Print a one-liner example for downloading the client `.p12` and password from Key Vault.

## 15. Documentation + final verification

- [x] 15.1 Update `README.md` run-order section (if present) to reference `04-Deploy-Certificate.ps1` then `05-Deploy-StrongSwanVm.ps1`; remove any reference to `-WebPassword` / `DEPLOY_WEB_PASSWORD`.
- [ ] 15.2 Run both scripts end-to-end against a Dev subscription (`$VerbosePreference = 'Continue'`); confirm clean first run.
- [ ] 15.3 Re-run both scripts; confirm no errors and no duplicate resources (VM, NIC, PIPs, NSG rules, role assignment, Key Vault secret versions).
- [ ] 15.4 Import the client `.p12` on a development machine, connect via native IKEv2 with **EAP-MSCHAPv2** (username/password), and confirm IPv4 + IPv6 reachability to a VNet resource.
- [ ] 15.5 Repeat the connection test using **client-cert** auth; confirm IPv4 + IPv6 reachability.
- [ ] 15.6 Tear down via `util/Remove-Rg.ps1` and confirm a fresh re-deploy works (exercises the Key Vault soft-delete path for secrets).
