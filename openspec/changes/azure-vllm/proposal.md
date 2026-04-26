## Why

The project's stated goal is to host an open-source LLM in the operator's own Azure tenant and let local AI tools (e.g. OpenCode) talk to it via an OpenAI-compatible API. Today the repo has core networking (`a-infrastructure/`) and shared services (`b-shared/`) but no actual inference workload — `c-workload/` is empty. Operators currently have nothing to point a client at.

This change introduces the first inference workload: a single-VM deployment of **vLLM** serving **Qwen2.5-Coder-7B-Instruct (AWQ-INT4)** on a T4 GPU, exposed publicly over HTTPS with a Let's Encrypt certificate and a shared bearer-token API key. Public exposure (no VPN dependency) is a deliberate choice for this first iteration: it keeps the deployment self-contained, lets a developer reach the endpoint from anywhere, and matches the pattern already proven in the reference IoT project (`iot-demo-build/azure-mosquitto`) of "Certbot + native TLS in the server + cloudapp.azure.com DNS label".

vLLM is chosen over Ollama because the project's near-term direction is multi-model, multi-user serving fronted by a LiteLLM proxy (deferred to a later change). vLLM's stricter OpenAI-spec compliance, mature `--tool-call-parser` support, paged-attention batching, and native `--ssl-*` + `--api-key` flags make it the right backend even at single-user scale. Certbot is chosen over a Caddy reverse proxy because vLLM already terminates TLS itself; adding Caddy would be redundant and would hide vLLM's own TLS configuration.

The model is held on a **persistent Managed Disk** that is created independently of the VM, attached at VM-create time, and detached before VM deletion so it survives VM rebuilds. The model is downloaded from Hugging Face directly to that disk by a `util/` script that uses `az vm run-command invoke` against the running VM — the operator's workstation never holds the bytes, and there is no Azure Storage account in the loop. If the data disk is ever lost, recovery is to re-run the download script (Hugging Face is the only path back, and that is explicitly accepted).

## What Changes

- **New** `c-workload/01-Deploy-LlmSubnet.ps1` — creates a public-facing subnet `snet-llm-vllm-<env>-<loc>-001` inside the existing workload VNet (provisioned by `a-infrastructure/03-deploy-workload-rg-vnet.ps1`) and an associated NSG `nsg-llm-vllm-<env>-001` with inbound rules for **22/tcp** (SSH), **80/tcp** (ACME HTTP-01 challenge), and **443/tcp** (vLLM API). All other inbound traffic denied via the NSG default. Idempotent.
- **New** `c-workload/02-Deploy-LlmKeyVaultSecret.ps1` — generates a 256-bit random API token, stores it as `vllm-api-key` in the existing shared Key Vault. Idempotent: re-uses the existing secret if present, only rotates when called with `-Rotate` switch.
- **New** `c-workload/03-Deploy-LlmIdentity.ps1` — creates the user-assigned managed identity that the VM will bind at create time, and grants it `get, list` on Key Vault secrets via Key Vault access policy. No storage permissions are granted (no storage account exists in this design). Idempotent.
- **New** `c-workload/04-Deploy-LlmPublicIp.ps1` — creates a static dual-stack public IP set: one IPv6 (primary) and one IPv4, both Standard SKU, with DNS labels `llm-<orgid>-<env>` and `llm-<orgid>-<env>-ipv4` under `<location>.cloudapp.azure.com`. The DNS label is what Let's Encrypt issues against — no external DNS provider is involved. Idempotent.
- **New** `c-workload/05-Deploy-LlmDataDisk.ps1` — creates a standalone Standard SSD (`StandardSSD_LRS`) Managed Disk `disk-llm-vllm-models-<env>-001` of size 8 GiB (E2 tier) in the workload RG, owned independently of any VM so it survives VM rebuilds. Idempotent (`disk show` pre-check). Refuses to recreate or resize an existing disk.
- **New** `c-workload/06-Deploy-LlmVm.ps1` — deploys the GPU VM (`Standard_NC4as_T4_v3`, Ubuntu 22.04 LTS) with the NVIDIA driver VM extension, binds the UAMI from script 03, attaches the public IPs from script 04, attaches the existing data disk from script 05 by resource ID at LUN 0 (`--attach-data-disks`, never `--data-disk-sizes-gb`), and passes a substituted cloud-init template (`c-workload/data/vllm-cloud-init.txt`) as `--custom-data`. Configures Azure auto-shutdown at a fixed UTC time. Idempotent. Errors clearly if the data disk is missing or already attached to another VM.
- **New** `c-workload/07-Test-LlmEndpoint.ps1` — smoke test that calls `GET /v1/models` and `POST /v1/chat/completions` (with a single `get_weather` tool definition) against the public HTTPS endpoint using the bearer token. Asserts a 200 response containing the served model name on the first call, and a `tool_calls` array on the second. Exits non-zero on any failure. Documents that `util/Download-LlmModelToDisk.ps1` must have been run at least once.
- **New** `c-workload/Stop-LlmVm.ps1` and `c-workload/Start-LlmVm.ps1` — convenience wrappers around `az vm deallocate` / `az vm start` for cost control between sessions.
- **New** `c-workload/Rotate-LlmApiKey.ps1` — generates a fresh API key, updates the Key Vault secret, runs `az vm run-command invoke` to rewrite `/etc/vllm/vllm.env` and restart the `vllm` systemd unit so it picks up the new key.
- **New** `c-workload/data/vllm-cloud-init.txt` — cloud-init template containing placeholders `#INIT_HOST_NAME#`, `#INIT_HOST_NAME_IPV4#`, `#INIT_KEY_VAULT_NAME#`, `#INIT_API_KEY_SECRET_NAME#`, `#INIT_UAMI_CLIENT_ID#`, `#INIT_CERT_EMAIL#`, `#INIT_ACME_STAGING_FLAG#`, `#INIT_VLLM_VERSION#`, `#INIT_SERVED_MODEL_NAME#`, `#INIT_MODEL_DIR_NAME#`, `#INIT_MODEL_MOUNT_POINT#`. Installs certbot, creates a `vllm` system user, formats the attached data disk with ext4 (only if it has no filesystem yet) and persistently mounts it at `/opt/models` via `/etc/fstab` using a filesystem `LABEL=`, sets up a Python venv, installs a pinned vLLM version, fetches the API key from Key Vault using the UAMI, writes `/etc/vllm/vllm.env`, registers a `/etc/letsencrypt/renewal-hooks/deploy/10-vllm-restart.sh` deploy hook, requests the initial Let's Encrypt certificate via `certbot certonly --standalone --preferred-challenges http`, copies the cert into `/etc/vllm/certs/`, and `enable`s (but does not `start`) a systemd unit `vllm.service`. The unit carries `ConditionPathExists=/opt/models/<modelDir>/config.json` so it stays inactive until the model is loaded onto the disk by the util script. Grants the venv's Python `cap_net_bind_service` so it can bind 443 without running as root.
- **New** `util/Download-LlmModelToDisk.ps1` — operator-triggered post-VM script. Uses `az vm run-command invoke` to execute an inline shell script on the running VM that pulls `Qwen/Qwen2.5-Coder-7B-Instruct-AWQ` from Hugging Face directly into `/opt/models/qwen2.5-coder-7b-awq/` on the attached data disk, then `systemctl start vllm`. Idempotent: the inline script short-circuits if `config.json` is already present on the disk. Operator's workstation never holds the bytes.
- **New** `util/Detach-LlmModelDisk.ps1` — operator-triggered script that idempotently `az vm deallocate`s the LLM VM, detaches the data disk, and (when `-DeleteVm` is passed) `az vm delete`s the VM. Tolerates already-deallocated, already-detached, and missing-VM states. The data disk is never deleted by this script.
- **New** `c-workload/README.md` — documents prerequisites (T4 quota, completed `a-infrastructure` and `b-shared` deployments), the deploy run order (01–07), the post-VM model-load step (`util/Download-LlmModelToDisk.ps1`), the rebuild-VM-keep-disk flow (`util/Detach-LlmModelDisk.ps1 -DeleteVm` → re-run `06`), expected hostnames, OpenCode configuration snippet, troubleshooting (cloud-init log location, vLLM systemd unit, `ConditionPathExists` semantics), cost estimate, and the explicit acknowledgement that data-disk loss means re-pulling from Hugging Face.
- **New** `docs/OpenCode-vllm-config.md` — copy-pasteable OpenCode provider configuration showing how to wire the deployed endpoint into `~/.config/opencode/opencode.json`.

## Capabilities

### New Capabilities
- `llm-inference-public`: Deployment of a public-facing OpenAI-compatible LLM inference endpoint on an Azure GPU VM. Covers vLLM as the inference engine, native TLS via vLLM's `--ssl-*` flags, automatic Let's Encrypt certificate issuance and renewal via Certbot, shared bearer-token authentication via vLLM's `--api-key`, dual-stack public IPs with `cloudapp.azure.com` DNS labels, model storage on a persistent Managed Disk that survives VM rebuilds, model fetched on demand from Hugging Face into the VM via a `util/` run-command script, secret material via shared Key Vault + UAMI, and an OpenAI-compatible smoke test. Does **not** cover multi-user authentication, per-user quotas, or model routing — those are deferred to a future `llm-inference-gateway` capability that will introduce LiteLLM. Does **not** include any teardown scripts inside `c-workload/`; reverse-direction operations are limited to the `util/Detach-LlmModelDisk.ps1` script which preserves the data disk by design.

### Modified Capabilities
<!-- None. `core-infrastructure` provides the workload VNet as-is; no requirement changes. The shared Key Vault from b-shared is consumed as-is. -->

## Impact

- **Files created**:
  - `c-workload/01-Deploy-LlmSubnet.ps1`
  - `c-workload/02-Deploy-LlmKeyVaultSecret.ps1`
  - `c-workload/03-Deploy-LlmIdentity.ps1`
  - `c-workload/04-Deploy-LlmPublicIp.ps1`
  - `c-workload/05-Deploy-LlmDataDisk.ps1`
  - `c-workload/06-Deploy-LlmVm.ps1`
  - `c-workload/07-Test-LlmEndpoint.ps1`
  - `c-workload/Stop-LlmVm.ps1`, `c-workload/Start-LlmVm.ps1`, `c-workload/Rotate-LlmApiKey.ps1`
  - `c-workload/data/vllm-cloud-init.txt`
  - `c-workload/README.md`
  - `util/Download-LlmModelToDisk.ps1`
  - `util/Detach-LlmModelDisk.ps1`
  - `docs/OpenCode-vllm-config.md`
- **Files NOT created**: no `9x-Remove-*.ps1` script in `c-workload/`. Removal of the workload-RG-level resources is the responsibility of `a-infrastructure/91-remove-workload-rg.ps1` (which cascade-deletes everything in the RG, including the data disk). Targeted intra-workload teardown can be added later as one-shot helpers in `util/` if and when the operator asks for it.
- **Devcontainer / tooling**: no new tooling required (Azure CLI + PowerShell already present). No local Python venv is created on the operator's machine for any reason. The Hugging Face download happens inside the VM, invoked remotely.
- **Prerequisites**:
  - `a-infrastructure/01..03` completed (workload RG + VNet exist).
  - `b-shared/02-Deploy-KeyVault.ps1` completed (shared Key Vault exists in access-policy mode).
  - Azure subscription has quota for one `Standard_NC4as_T4_v3` in the chosen region (this is the most likely failure mode for a fresh subscription; documented in README and called out at the start of script 06 with a clear error if `az vm list-usage` shows zero quota).
  - Operator must supply an `-AcmeEmail` (or `DEPLOY_ACME_EMAIL`) for Let's Encrypt account registration.
  - VM has outbound internet access (already required for `apt`, `pip`, ACME, NVIDIA repositories) — used to reach `huggingface.co` during the model-load step.
- **Networking impact**: Adds one subnet to the existing workload VNet (under `core-infrastructure`'s `vnet-llm-workload-<env>-<loc>-001`), one NSG with three inbound allow rules (22/80/443), one set of dual-stack static public IPs. No changes to VNet peering or to existing subnets. No UDRs.
- **Storage impact**: One Standard SSD Managed Disk (8 GiB, E2). No Azure Storage account, no Blob containers, no SAS tokens, no data-plane Storage RBAC.
- **Secret material**:
  - New Key Vault secret `vllm-api-key` (256-bit random; rotatable via `Rotate-LlmApiKey.ps1`).
  - The Let's Encrypt account key and certificate live on the VM disk under `/etc/letsencrypt/`; not in Key Vault. (Acceptable per the Mosquitto reference pattern — the cert is publicly issued anyway and re-issued on rebuild.)
- **Cost (informational, not a contract)**: VM ~US$380/month at 24×7 list price; ~US$30–80/month with night auto-shutdown and weekend deallocation. Persistent data disk (Standard SSD E2, 8 GiB) ~US$0.60/month. Public IPv4 ~US$3.65/month (Standard SKU, static); IPv6 free. Key Vault secret operations negligible.
- **Threat model accepted by this change**:
  - **Public TCP 22 from the internet** — matches the IoT-repo reference pattern. SSH is key-only (`--generate-ssh-keys`). Operators concerned about scanner noise can replace this with Azure Bastion or JIT in a follow-up; explicitly out of scope here.
  - **Single shared bearer token** — leaks of the token grant full inference access until rotation. Mitigated by `Rotate-LlmApiKey.ps1` and by Key Vault as the source of truth.
  - **Public exposure of the model endpoint** — anyone with the token can run inference and run up the GPU bill. Multi-user authentication and per-key quotas are explicitly deferred to a later `llm-inference-gateway` change introducing LiteLLM.
  - **Data-disk loss = Hugging Face dependency for recovery** — the canonical store of the model bytes is the data disk. If it is lost (accidental delete, region failure), recovery is to re-run `util/Download-LlmModelToDisk.ps1`, which depends on `huggingface.co` being reachable and the upstream repo existing. Explicitly accepted.
- **Out of scope (explicit)**:
  - LiteLLM proxy and any form of per-user authentication, quotas, or routing.
  - Multi-model serving (vLLM is one process, one model at a time).
  - Custom domain CNAMEs (the `cloudapp.azure.com` label is the deployed DNS).
  - Bastion / JIT for SSH.
  - Cert material in Key Vault (cert lives on VM disk, certbot manages it).
  - High availability, multi-region, GPU autoscale.
  - Any `9x-Remove-*.ps1` script in `c-workload/`. RG-level teardown remains the responsibility of `a-infrastructure/`.
  - Azure Storage. The model is held only on the data disk.
