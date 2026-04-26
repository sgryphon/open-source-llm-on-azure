# Implementation Tasks

## 1. Repo plumbing

- [ ] 1.1 Create `c-workload/` and `c-workload/data/` folders.
- [ ] 1.2 Add `c-workload/temp/` to `.gitignore` (the substituted cloud-init lands here).
- [ ] 1.3 Stub `c-workload/README.md` (full content filled in by task 13.1).

## 2. `00-Stage-Model.ps1` — model staging helper

- [ ] 2.1 Author the script with `[CmdletBinding()]`, comment-based help, `$ErrorActionPreference='Stop'`, and standard parameters (`-Environment`, `-Location`, `-OrgId`, `-ModelRepoId` defaulting to `Qwen/Qwen2.5-Coder-7B-Instruct-AWQ`).
- [ ] 2.2 Implement local Python venv bootstrap under `./temp/hf-stage/` with `huggingface-hub` pinned.
- [ ] 2.3 Implement HF download into `./temp/models/qwen2.5-coder-7b-awq/`, with skip-if-present idempotency.
- [ ] 2.4 Implement `tar` + `zstd` into `./temp/qwen2.5-coder-7b-awq.tar.zst`.
- [ ] 2.5 Implement upload to the workload storage container `models`, skipping when blob `Content-MD5` matches local.
- [ ] 2.6 Add `Write-Verbose` traces and at least one `.EXAMPLE`.

## 3. `01-Deploy-LlmStorage.ps1` — workload storage

- [ ] 3.1 Author script skeleton (params, help, verbose, error stop).
- [ ] 3.2 Resolve workload RG name (`rg-llm-workload-<env>-001`).
- [ ] 3.3 Create the storage account `stllm<orgid><env>001` (Standard_LRS, TLS 1.2, public blob disabled), guarded by `storage account show`.
- [ ] 3.4 Create the private container `models`, guarded by `storage container show`.
- [ ] 3.5 Apply CAF tags.

## 4. `02-Deploy-LlmSubnet.ps1` — subnet + NSG

- [ ] 4.1 Author script skeleton.
- [ ] 4.2 Compute IPv6 prefix `fd<gg>:<gggg>:<gggggg>:0301::/64` and IPv4 prefix `10.<gg>.3.32/27` from `UlaGlobalId`.
- [ ] 4.3 Create the subnet inside `vnet-llm-workload-<env>-<loc>-001`, guarded by `network vnet subnet show`.
- [ ] 4.4 Create the NSG `nsg-llm-vllm-<env>-001` and the three inbound allow rules (22, 80, 443).
- [ ] 4.5 Associate the NSG with the subnet.
- [ ] 4.6 Apply CAF tags.

## 5. `03-Deploy-LlmKeyVaultSecret.ps1` — API key

- [ ] 5.1 Author script skeleton with `-Rotate` switch.
- [ ] 5.2 Resolve shared Key Vault name from `b-shared` conventions.
- [ ] 5.3 Generate a 256-bit URL-safe-base64 random value when creating or rotating.
- [ ] 5.4 Without `-Rotate`: skip if `vllm-api-key` already exists.
- [ ] 5.5 With `-Rotate`: set a new secret version.

## 6. `04-Deploy-LlmIdentity.ps1` — UAMI + permissions

- [ ] 6.1 Author script skeleton.
- [ ] 6.2 Create UAMI `id-llm-vllm-<env>-001` in workload RG, guarded by `identity show`.
- [ ] 6.3 Grant the UAMI `get,list` on secrets in the shared Key Vault via `keyvault set-policy` (idempotent).
- [ ] 6.4 Grant the UAMI `Storage Blob Data Reader` scoped to the `models` container, guarded by `role assignment list`.
- [ ] 6.5 Apply CAF tags.

## 7. `05-Deploy-LlmPublicIp.ps1` — dual-stack PIPs

- [ ] 7.1 Author script skeleton.
- [ ] 7.2 Create IPv6 PIP `pip-llm-vllm-<env>-<loc>-001` (Standard, Static, DNS label `llm-<orgid>-<env>`), guarded by `public-ip show`.
- [ ] 7.3 Create IPv4 PIP `pipv4-llm-vllm-<env>-<loc>-001` (Standard, Static, DNS label `llm-<orgid>-<env>-ipv4`), guarded by `public-ip show`.
- [ ] 7.4 Apply CAF tags. Emit both FQDNs to verbose output.

## 8. `data/vllm-cloud-init.txt` — cloud-init template

- [ ] 8.1 Write the template header (`#cloud-config`, `package_update`, `package_upgrade: false`).
- [ ] 8.2 Add `packages:` for `certbot`, `tar`, `zstd`, `python3-venv`, `python3-pip`, `libcap2-bin`, `jq`, `curl`, Azure CLI prerequisites.
- [ ] 8.3 Add the Azure CLI install snippet under `runcmd` (Microsoft script repo, idempotent guard).
- [ ] 8.4 Add `runcmd` step: `az login --identity --username #INIT_UAMI_CLIENT_ID#`.
- [ ] 8.5 Add `runcmd` step: fetch the API key from Key Vault and write `/etc/vllm/vllm.env` mode 0600 owned by `vllm:vllm`.
- [ ] 8.6 Add `runcmd` step: download the model archive blob via `az storage blob download --auth-mode login` with a retry loop covering RBAC propagation.
- [ ] 8.7 Add `runcmd` step: extract under `/opt/models/qwen2.5-coder-7b-awq/`, then remove the archive.
- [ ] 8.8 Add `runcmd` step: create the `vllm` system user, create `/opt/vllm/.venv`, `pip install vllm==#INIT_VLLM_VERSION#`, `setcap 'cap_net_bind_service=+ep'` on the venv's Python.
- [ ] 8.9 Add `runcmd` step: write `/etc/letsencrypt/renewal-hooks/deploy/10-vllm-restart.sh` with the documented body and mode 0755.
- [ ] 8.10 Add `runcmd` step: run `certbot certonly --standalone --preferred-challenges http --cert-name vllm-cert -d #INIT_HOST_NAME# -d #INIT_HOST_NAME_IPV4# -n --agree-tos -m #INIT_CERT_EMAIL# #INIT_ACME_STAGING_FLAG#`, then invoke the deploy hook with `RENEWED_LINEAGE` set so the initial cert lands in `/etc/vllm/certs/`.
- [ ] 8.11 Add `write_files:` entry for `/etc/systemd/system/vllm.service` matching the design's unit definition (with `--served-model-name #INIT_SERVED_MODEL_NAME#` and `--max-model-len 32768`).
- [ ] 8.12 Add `runcmd` step: `systemctl daemon-reload && systemctl enable --now vllm`.

## 9. `06-Deploy-LlmVm.ps1` — VM + cloud-init

- [ ] 9.1 Author script skeleton with `-AcmeEmail`, `-AcmeStaging`, `-VllmVersion`, `-ShutdownUtc` parameters.
- [ ] 9.2 Pre-check `az vm list-usage` for `standardNCASv3Family`; abort with a clear message if zero.
- [ ] 9.3 Resolve names of: subnet, NSG, both PIPs, UAMI, storage account, shared Key Vault.
- [ ] 9.4 Read `data/vllm-cloud-init.txt`, substitute every `#INIT_*#` token, write to `temp/vllm-cloud-init.txt~`. Assert no secret value appears in the substituted file.
- [ ] 9.5 Create NIC with both PIPs attached (IPv6 primary), guarded by `nic show`.
- [ ] 9.6 Create the VM (`Standard_NC4as_T4_v3`, Ubuntu 22.04 LTS, `--assign-identity` UAMI, `--custom-data` substituted file, `--generate-ssh-keys`, no password auth), guarded by `vm show`.
- [ ] 9.7 Apply NVIDIA GPU Driver Linux extension, guarded by `vm extension show`.
- [ ] 9.8 Configure `az vm auto-shutdown` at `-ShutdownUtc` (default `0900`).
- [ ] 9.9 Wait for `cloud-init status --wait` via `vm run-command invoke`; on failure, dump `/var/log/cloud-init-output.log` to the operator and exit non-zero.
- [ ] 9.10 Apply CAF tags to NIC and VM. Emit IPv6 and IPv4 FQDNs to verbose output.

## 10. `07-Test-LlmEndpoint.ps1` — smoke test

- [ ] 10.1 Author script skeleton with `-AcmeStaging`, `-TestIpv4` switches.
- [ ] 10.2 Fetch `vllm-api-key` from the shared Key Vault and the IPv6 FQDN from the PIP.
- [ ] 10.3 Call `GET /v1/models`; assert 200 and `qwen2.5-coder-7b` present in `data[].id`.
- [ ] 10.4 Call `POST /v1/chat/completions` with the `get_weather` tool and a London weather prompt; assert 200 and `choices[0].message.tool_calls[0].function.name == 'get_weather'`.
- [ ] 10.5 Use `-SkipCertificateCheck` only when `-AcmeStaging` is passed; emit a warning when doing so.
- [ ] 10.6 Exit 0 on both passes; emit diagnostic body and exit non-zero on any failure.

## 11. `91-Remove-Llm.ps1` — teardown

- [ ] 11.1 Author script skeleton (`-Environment`, `-Scope` with values `All`, `Vm`).
- [ ] 11.2 Delete in reverse order: VM → OS disk → NIC → IPv6 PIP → IPv4 PIP → NSG (after disassociating from subnet) → subnet → UAMI → storage account → KV access policy entry for the UAMI → `vllm-api-key` secret.
- [ ] 11.3 Each delete uses `--yes` and is preceded by a `show` check so missing resources do not error.
- [ ] 11.4 With `-Scope Vm`: stop after deleting VM, OS disk, and NIC.
- [ ] 11.5 Assert that the workload RG, workload VNet, shared Key Vault, and other capability-owned resources are not touched.

## 12. Operational utilities

- [ ] 12.1 `Stop-LlmVm.ps1` — `az vm deallocate` against `vmllmvllm001`, idempotent.
- [ ] 12.2 `Start-LlmVm.ps1` — `az vm start` against `vmllmvllm001`, idempotent.
- [ ] 12.3 `Rotate-LlmApiKey.ps1` — set new `vllm-api-key` version, then `vm run-command invoke` to rewrite `/etc/vllm/vllm.env` and `systemctl restart vllm`.

## 13. Documentation

- [ ] 13.1 Fill in `c-workload/README.md`: prerequisites (T4 quota, prior capabilities), run order (00–07), utility scripts, hostname pattern, OpenCode wiring pointer, cost notes, troubleshooting, teardown order.
- [ ] 13.2 Create `docs/OpenCode-vllm-config.md` with a copy-pasteable `~/.config/opencode/opencode.json` snippet pointing at the IPv6 FQDN with the bearer token from Key Vault.

## 14. End-to-end validation

- [ ] 14.1 In a clean dev subscription with T4 quota, run `a-infrastructure/01..03`, `b-shared/01..02`, then `c-workload/00..07` in order; confirm `07-Test-LlmEndpoint.ps1` exits 0 against the production Let's Encrypt cert.
- [ ] 14.2 Re-run every deploy script (`01..06`) and confirm each is a no-op with exit 0.
- [ ] 14.3 Run `Rotate-LlmApiKey.ps1` and confirm the new key works while the old one is rejected, without VM redeploy.
- [ ] 14.4 Run `91-Remove-Llm.ps1`; confirm only resources owned by this capability are removed, and the workload RG/VNet, shared Key Vault, and prior capability resources remain.
