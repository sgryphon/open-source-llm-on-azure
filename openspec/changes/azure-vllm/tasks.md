# Implementation Tasks

## 1. Repo plumbing

- [x] 1.1 Create `c-workload/` and `c-workload/data/` folders.
- [x] 1.2 Add `c-workload/temp/` to `.gitignore` (the substituted cloud-init lands here).
- [x] 1.3 Stub `c-workload/README.md` (full content filled in by task 11.1).

## 2. `01-Deploy-LlmSubnet.ps1` — subnet + NSG

- [x] 2.1 Author script skeleton (`[CmdletBinding()]`, comment-based help, `$ErrorActionPreference='Stop'`, standard parameters with env-var fallbacks).
- [x] 2.2 Compute IPv6 prefix `fd<gg>:<gggg>:<gggggg>:0201::/64` and IPv4 prefix `10.<gg>.2.32/27` from `UlaGlobalId` (workload VNet ID `02`, subnet ID `01`).
- [x] 2.3 Create the subnet inside `vnet-llm-workload-<env>-<loc>-001`, guarded by `network vnet subnet show`.
- [x] 2.4 Create the NSG `nsg-llm-vllm-<env>-001` and the three inbound allow rules (22, 80, 443) with the documented priorities.
- [x] 2.5 Associate the NSG with the subnet (idempotent).
- [x] 2.6 Apply CAF tags to the NSG.

## 3. `02-Deploy-LlmKeyVaultSecret.ps1` — API key

- [x] 3.1 Author script skeleton with `-Rotate` switch.
- [x] 3.2 Resolve shared Key Vault name from `b-shared` conventions.
- [x] 3.3 Generate a 256-bit URL-safe-base64 random value when creating or rotating.
- [x] 3.4 Without `-Rotate`: skip if `vllm-api-key` already exists.
- [x] 3.5 With `-Rotate`: set a new secret version.

## 4. `03-Deploy-LlmIdentity.ps1` — UAMI + Key Vault permission

- [x] 4.1 Author script skeleton.
- [x] 4.2 Create UAMI `id-llm-vllm-<env>-001` in workload RG, guarded by `identity show`.
- [x] 4.3 Grant the UAMI `get,list` on secrets in the shared Key Vault via `keyvault set-policy` (idempotent).
- [x] 4.4 Assert no Storage RBAC role assignment is created (script does not call `az role assignment create`).
- [x] 4.5 Apply CAF tags to the UAMI.

## 5. `04-Deploy-LlmPublicIp.ps1` — dual-stack PIPs

- [x] 5.1 Author script skeleton.
- [x] 5.2 Create IPv6 PIP `pip-llm-vllm-<env>-<loc>-001` (Standard, Static, DNS label `llm-<orgid>-<env>`), guarded by `public-ip show`.
- [x] 5.3 Create IPv4 PIP `pipv4-llm-vllm-<env>-<loc>-001` (Standard, Static, DNS label `llm-<orgid>-<env>-ipv4`), guarded by `public-ip show`.
- [x] 5.4 Apply CAF tags. Emit both FQDNs to verbose output.

## 6. `05-Deploy-LlmDataDisk.ps1` — persistent data disk

- [x] 6.1 Author script skeleton.
- [x] 6.2 Create standalone Managed Disk `disk-llm-vllm-models-<env>-001` (`StandardSSD_LRS`, 8 GiB), guarded by `disk show`. Use `az disk create`, never `az vm create --data-disk-sizes-gb`.
- [x] 6.3 On re-run with an existing disk, exit 0 without modification (no resize, no SKU change, no tag rewrite).
- [x] 6.4 Apply CAF tags on initial create.

## 7. `data/vllm-cloud-init.txt` — cloud-init template

- [x] 7.1 Write the template header (`#cloud-config`, `package_update`, `package_upgrade: false`).
- [x] 7.2 Add `packages:` for `certbot`, `python3-venv`, `python3-pip`, `libcap2-bin`, `jq`, `curl`, Azure CLI prerequisites.
- [x] 7.3 Add the Azure CLI install snippet under `runcmd` (Microsoft script repo, idempotent guard).
- [x] 7.4 Add `runcmd` step: wait for the data-disk block device to appear, run `mkfs.ext4 -L llm-models <device>` only if `blkid` reports no filesystem.
- [x] 7.5 Add `runcmd` step: ensure `/etc/fstab` contains `LABEL=llm-models /opt/models ext4 defaults,nofail 0 2`, run `mkdir -p /opt/models`, run `mount -a`.
- [x] 7.6 Add `runcmd` step: create the `vllm` system user, `chown vllm:vllm /opt/models`.
- [x] 7.7 Add `runcmd` step: `az login --identity --username #INIT_UAMI_CLIENT_ID#`.
- [x] 7.8 Add `runcmd` step: fetch the API key from Key Vault and write `/etc/vllm/vllm.env` mode 0600 owned by `vllm:vllm`.
- [x] 7.9 Add `runcmd` step: create `/opt/vllm/.venv`, `pip install vllm==#INIT_VLLM_VERSION#`, `setcap 'cap_net_bind_service=+ep'` on the venv's Python.
- [x] 7.10 Add `runcmd` step: write `/etc/letsencrypt/renewal-hooks/deploy/10-vllm-restart.sh` with the documented body and mode 0755.
- [x] 7.11 Add `runcmd` step: run `certbot certonly --standalone --preferred-challenges http --cert-name vllm-cert -d #INIT_HOST_NAME# -d #INIT_HOST_NAME_IPV4# -n --agree-tos -m #INIT_CERT_EMAIL# #INIT_ACME_STAGING_FLAG#`, then invoke the deploy hook with `RENEWED_LINEAGE` set so the initial cert lands in `/etc/vllm/certs/`.
- [x] 7.12 Add `write_files:` entry for `/etc/systemd/system/vllm.service` matching the design's unit definition (with `ConditionPathExists=#INIT_MODEL_MOUNT_POINT#/#INIT_MODEL_DIR_NAME#/config.json`, `--served-model-name #INIT_SERVED_MODEL_NAME#`, `--model #INIT_MODEL_MOUNT_POINT#/#INIT_MODEL_DIR_NAME#`, and `--max-model-len 32768`).
- [x] 7.13 Add `runcmd` step: `systemctl daemon-reload && systemctl enable vllm` (do NOT `start` — the `ConditionPathExists` guard would silently fail anyway, and explicit not-starting documents the intent).

## 8. `06-Deploy-LlmVm.ps1` — VM + cloud-init + data-disk attach

- [x] 8.1 Author script skeleton with `-AcmeEmail`, `-AcmeStaging`, `-VllmVersion`, `-ShutdownUtc` parameters.
- [x] 8.2 Pre-check `az vm list-usage` for `standardNCASv3Family`; abort with a clear message if zero.
- [x] 8.3 Pre-check `az disk show` for the data disk: must exist, must be `Unattached` or attached to `vmllmvllm001`. Fail clearly if attached elsewhere.
- [x] 8.4 Resolve names of: subnet, NSG, both PIPs, UAMI, shared Key Vault, data disk.
- [x] 8.5 Read `data/vllm-cloud-init.txt`, substitute every `#INIT_*#` token, write to `temp/vllm-cloud-init.txt~`. Assert no secret value appears in the substituted file.
- [x] 8.6 Create NIC with both PIPs attached (IPv6 primary), guarded by `nic show`.
- [x] 8.7 Create the VM (`Standard_NC4as_T4_v3`, Ubuntu 22.04 LTS, `--assign-identity` UAMI, `--attach-data-disks <disk-id>` only — NEVER `--data-disk-sizes-gb`, `--custom-data` substituted file, `--generate-ssh-keys`, no password auth), guarded by `vm show`.
- [x] 8.8 Apply NVIDIA GPU Driver Linux extension, guarded by `vm extension show`.
- [x] 8.9 Configure `az vm auto-shutdown` at `-ShutdownUtc` (default `0900`).
- [x] 8.10 Wait for `cloud-init status --wait` via `vm run-command invoke`; on failure, dump `/var/log/cloud-init-output.log` to the operator and exit non-zero.
- [x] 8.11 Apply CAF tags to NIC and VM. Emit IPv6 and IPv4 FQDNs to verbose output, plus a reminder line that `util/Download-LlmModelToDisk.ps1` is the next step.

## 9. `07-Test-LlmEndpoint.ps1` — smoke test

- [x] 9.1 Author script skeleton with `-AcmeStaging`, `-TestIpv4` switches.
- [x] 9.2 Fetch `vllm-api-key` from the shared Key Vault and the IPv6 FQDN from the PIP.
- [x] 9.3 Call `GET /v1/models`; assert 200 and `qwen2.5-coder-7b` present in `data[].id`. On TCP-level failure, emit a hint that points at `util/Download-LlmModelToDisk.ps1`.
- [x] 9.4 Call `POST /v1/chat/completions` with the `get_weather` tool and a London weather prompt; assert 200 and `choices[0].message.tool_calls[0].function.name == 'get_weather'`.
- [x] 9.5 Use `-SkipCertificateCheck` only when `-AcmeStaging` is passed; emit a warning when doing so.
- [x] 9.6 Exit 0 on both passes; emit diagnostic body and exit non-zero on any failure.

## 10. Operational utilities

- [x] 10.1 `Stop-LlmVm.ps1` — `az vm deallocate` against `vmllmvllm001`, idempotent.
- [x] 10.2 `Start-LlmVm.ps1` — `az vm start` against `vmllmvllm001`, idempotent.
- [x] 10.3 `Rotate-LlmApiKey.ps1` — set new `vllm-api-key` version, then `vm run-command invoke` to rewrite `/etc/vllm/vllm.env` and `systemctl restart vllm`.

## 11. `util/` cross-cutting helpers

- [x] 11.1 `util/Download-LlmModelToDisk.ps1` — author script skeleton with `-Environment`, `-Location`, `-ModelRepoId`, `-ModelDirName` parameters and standard env-var fallbacks.
- [x] 11.2 Build the inline shell script: `set -euo pipefail`, short-circuit on `config.json` presence, `pip install -q huggingface-hub` into the existing vLLM venv, `huggingface-cli download` into `/opt/models/<dir>`, `chown -R vllm:vllm /opt/models`, `systemctl start vllm`, verify `is-active`, dump journal on failure.
- [x] 11.3 Invoke `az vm run-command invoke --command-id RunShellScript --scripts <inline>`; stream output to operator.
- [x] 11.4 Confirm operator workstation never receives model bytes (the run-command body uses HF→VM, not HF→workstation).
- [x] 11.5 `util/Detach-LlmModelDisk.ps1` — author script skeleton with `-Environment` and `-DeleteVm` switch.
- [x] 11.6 Implement `az vm deallocate` (idempotent: tolerate already-deallocated and missing-VM).
- [x] 11.7 Implement `az vm disk detach` (idempotent: tolerate already-detached).
- [x] 11.8 With `-DeleteVm`: implement `az vm delete --yes`. Without `-DeleteVm`: stop after detach.
- [x] 11.9 Assert the script never deletes the data disk, regardless of flags.

## 12. Documentation

- [x] 12.1 Fill in `c-workload/README.md`: prerequisites (T4 quota, prior capabilities), deploy order (01–06), the model-load step (`util/Download-LlmModelToDisk.ps1`), the smoke-test step (07), utility scripts, the rebuild-VM-keep-disk flow (`util/Detach-LlmModelDisk.ps1 -DeleteVm` followed by re-running `06`), hostname pattern, OpenCode wiring pointer, cost notes, troubleshooting (cloud-init log, vLLM systemd unit, `ConditionPathExists`, certbot logs), the HF-availability acknowledgement for DR, and the explicit note that no `9x-Remove` script exists in `c-workload/`.
- [x] 12.2 Create `docs/OpenCode-vllm-config.md` with a copy-pasteable `~/.config/opencode/opencode.json` snippet pointing at the IPv6 FQDN with the bearer token from Key Vault.

## 13. End-to-end validation

- [ ] 13.1 In a clean dev subscription with T4 quota, run `a-infrastructure/01..02`, `b-shared/01..02`, then `c-workload/01..06` in order; confirm cloud-init completes and cert is issued; confirm `vllm.service` is `enabled` but `inactive`.
- [ ] 13.2 Run `util/Download-LlmModelToDisk.ps1`; confirm it succeeds and `vllm.service` becomes `active`.
- [ ] 13.3 Run `c-workload/07-Test-LlmEndpoint.ps1`; confirm it exits 0 against the production Let's Encrypt cert.
- [ ] 13.4 Re-run every deploy script (`01..06`) and confirm each is a no-op with exit 0.
- [ ] 13.5 Re-run `util/Download-LlmModelToDisk.ps1` and confirm it short-circuits with exit 0 (no HF download).
- [ ] 13.6 Run `Rotate-LlmApiKey.ps1` and confirm the new key works while the old one is rejected, without VM redeploy.
- [ ] 13.7 Run `util/Detach-LlmModelDisk.ps1 -DeleteVm`; confirm VM and OS disk are gone, data disk remains in `Unattached` state, and the model files are intact (verifiable after the next attach).
- [ ] 13.8 Re-run `c-workload/06-Deploy-LlmVm.ps1`; confirm the same data disk is reattached, cloud-init does not reformat it (`mkfs` skipped), the existing `LABEL=llm-models` mount works, `vllm.service` starts automatically because `ConditionPathExists` is satisfied immediately, and `07-Test-LlmEndpoint.ps1` passes again without re-running the model-download step.
