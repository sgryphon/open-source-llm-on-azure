## Why

The project's stated goal is to host an open-source LLM in the operator's own Azure tenant and let local AI tools (e.g. OpenCode) talk to it via an OpenAI-compatible API. Today the repo has core networking (`a-infrastructure/`) and shared services (`b-shared/`) but no actual inference workload — `c-workload/` is empty. Operators currently have nothing to point a client at.

This change introduces the first inference workload: a single-VM deployment of **vLLM** serving **Qwen2.5-Coder-7B-Instruct (AWQ-INT4)** on a T4 GPU, exposed publicly over HTTPS with a Let's Encrypt certificate and a shared bearer-token API key. Public exposure (no VPN dependency) is a deliberate choice for this first iteration: it keeps the deployment self-contained, lets a developer reach the endpoint from anywhere, and matches the pattern already proven in the reference IoT project (`iot-demo-build/azure-mosquitto`) of "Certbot + native TLS in the server + cloudapp.azure.com DNS label".

vLLM is chosen over Ollama because the project's near-term direction is multi-model, multi-user serving fronted by a LiteLLM proxy (deferred to a later change). vLLM's stricter OpenAI-spec compliance, mature `--tool-call-parser` support, paged-attention batching, and native `--ssl-*` + `--api-key` flags make it the right backend even at single-user scale. Certbot is chosen over a Caddy reverse proxy because vLLM already terminates TLS itself; adding Caddy would be redundant and would hide vLLM's own TLS configuration.

## What Changes

- **New** `c-workload/00-Stage-Model.ps1` — one-time helper that downloads `Qwen/Qwen2.5-Coder-7B-Instruct-AWQ` from Hugging Face (via `huggingface-hub` in a temp Python venv on the operator's machine), packs it with `tar` + `zstd`, and uploads the archive to a blob in the workload storage account. Idempotent: skips download if a local archive already exists in `./temp/`, skips upload if the blob already exists with a matching `Content-MD5`.
- **New** `c-workload/01-Deploy-LlmStorage.ps1` — creates a Standard_LRS storage account in the workload RG with a single private container named `models`. Idempotent (`storage account show` + `storage container show` pre-checks).
- **New** `c-workload/02-Deploy-LlmSubnet.ps1` — creates a public-facing subnet `snet-llm-<env>-<loc>-001` inside the existing workload VNet (provisioned by `a-infrastructure/03-deploy-workload-rg-vnet.ps1`) and an associated NSG `nsg-llm-<env>-001` with inbound rules for **22/tcp** (SSH), **80/tcp** (ACME HTTP-01 challenge), and **443/tcp** (vLLM API). All other inbound traffic denied via the NSG default. Idempotent.
- **New** `c-workload/03-Deploy-LlmKeyVaultSecret.ps1` — generates a 256-bit random API token, stores it as `vllm-api-key` in the existing shared Key Vault, and grants the workload VM's user-assigned managed identity (created later by script 05) `get, list` permissions on secrets via Key Vault access policy. Idempotent: re-uses the existing secret if present, only rotates when called with `-Rotate` switch.
- **New** `c-workload/04-Deploy-LlmIdentity.ps1` — creates the user-assigned managed identity that the VM will bind at create time, grants it `get` on the model archive blob in storage (data-plane RBAC: `Storage Blob Data Reader` scoped to the container) and `get, list` on Key Vault secrets. Idempotent.
- **New** `c-workload/05-Deploy-LlmPublicIp.ps1` — creates a static dual-stack public IP set: one IPv6 (primary) and one IPv4, both Standard SKU, with DNS labels `llm-<orgid>-<env>` and `llm-<orgid>-<env>-ipv4` under `<location>.cloudapp.azure.com`. The DNS label is what Let's Encrypt issues against — no external DNS provider is involved. Idempotent.
- **New** `c-workload/06-Deploy-LlmVm.ps1` — deploys the GPU VM (`Standard_NC4as_T4_v3`, Ubuntu 22.04 LTS) with the NVIDIA driver VM extension, binds the UAMI from script 04, attaches the public IPs from script 05, and passes a substituted cloud-init template (`c-workload/data/vllm-cloud-init.txt`) as `--custom-data`. Configures Azure auto-shutdown at a fixed UTC time. Idempotent.
- **New** `c-workload/07-Test-LlmEndpoint.ps1` — smoke test that calls `GET /v1/models` and `POST /v1/chat/completions` (with a single `get_weather` tool definition) against the public HTTPS endpoint using the bearer token. Asserts a 200 response containing the served model name on the first call, and a `tool_calls` array on the second. Exits non-zero on any failure.
- **New** `c-workload/91-Remove-Llm.ps1` — deletes the workload-RG resources created by this change in reverse order (VM, NIC, public IPs, NSG, subnet association, storage account, UAMI, Key Vault secret access policy entry, Key Vault secret). Uses `--yes` and tolerates already-removed resources.
- **New** `c-workload/Stop-LlmVm.ps1` and `c-workload/Start-LlmVm.ps1` — convenience wrappers around `az vm deallocate` / `az vm start` for cost control between sessions.
- **New** `c-workload/Rotate-LlmApiKey.ps1` — generates a fresh API key, updates the Key Vault secret, runs `az vm run-command invoke` to restart the `vllm` systemd unit so it picks up the new key from `/etc/vllm/vllm.env` (which is itself refreshed at boot from Key Vault — for in-place rotation between reboots, the run-command also rewrites `/etc/vllm/vllm.env`).
- **New** `c-workload/data/vllm-cloud-init.txt` — cloud-init template containing placeholders `#INIT_HOST_NAME#`, `#INIT_API_KEY_SECRET_URI#`, `#INIT_MODEL_BLOB_URL#`, `#INIT_UAMI_CLIENT_ID#`, `#INIT_CERT_EMAIL#`, and `#INIT_ACME_STAGING_FLAG#`. Installs certbot, creates a `vllm` system user, sets up a Python venv, installs a pinned vLLM version, downloads the staged model archive from blob storage using the UAMI, fetches the API key from Key Vault using the UAMI, writes `/etc/vllm/vllm.env`, registers a `/etc/letsencrypt/renewal-hooks/deploy/10-vllm-restart.sh` deploy hook, requests the initial Let's Encrypt certificate via `certbot certonly --standalone --preferred-challenges http`, copies the cert into `/etc/vllm/certs/`, and starts a systemd unit `vllm.service` that runs `vllm serve` on `[::]:443` with `--ssl-certfile`, `--ssl-keyfile`, `--api-key`, `--model`, `--served-model-name`, `--tool-call-parser hermes`, `--enable-auto-tool-choice`, and `--max-model-len 32768`. Grants the venv's Python `cap_net_bind_service` so it can bind 443 without running as root.
- **New** `c-workload/README.md` — documents prerequisites (T4 quota, completed `a-infrastructure` and `b-shared` deployments, model staged), run order, expected hostnames, OpenCode configuration snippet, troubleshooting (cloud-init log location, vLLM systemd unit), cost estimate, and teardown order.
- **New** `docs/OpenCode-vllm-config.md` — copy-pasteable OpenCode provider configuration showing how to wire the deployed endpoint into `~/.config/opencode/opencode.json`.

## Capabilities

### New Capabilities
- `llm-inference-public`: Deployment of a public-facing OpenAI-compatible LLM inference endpoint on an Azure GPU VM. Covers vLLM as the inference engine, native TLS via vLLM's `--ssl-*` flags, automatic Let's Encrypt certificate issuance and renewal via Certbot, shared bearer-token authentication via vLLM's `--api-key`, dual-stack public IPs with `cloudapp.azure.com` DNS labels, model staging via Azure Storage blob, secret material via shared Key Vault + UAMI, and an OpenAI-compatible smoke test. Does **not** cover multi-user authentication, per-user quotas, or model routing — those are deferred to a future `llm-inference-gateway` capability that will introduce LiteLLM.

### Modified Capabilities
<!-- None. `core-infrastructure` provides the workload VNet as-is; no requirement changes. The shared Key Vault from b-shared is consumed as-is. -->

## Impact

- **Files created**:
  - `c-workload/00-Stage-Model.ps1`
  - `c-workload/01-Deploy-LlmStorage.ps1`
  - `c-workload/02-Deploy-LlmSubnet.ps1`
  - `c-workload/03-Deploy-LlmKeyVaultSecret.ps1`
  - `c-workload/04-Deploy-LlmIdentity.ps1`
  - `c-workload/05-Deploy-LlmPublicIp.ps1`
  - `c-workload/06-Deploy-LlmVm.ps1`
  - `c-workload/07-Test-LlmEndpoint.ps1`
  - `c-workload/91-Remove-Llm.ps1`
  - `c-workload/Stop-LlmVm.ps1`, `c-workload/Start-LlmVm.ps1`, `c-workload/Rotate-LlmApiKey.ps1`
  - `c-workload/data/vllm-cloud-init.txt`
  - `c-workload/README.md`
  - `docs/OpenCode-vllm-config.md`
- **Devcontainer / tooling**: no new tooling required (Azure CLI + PowerShell already present); a Python venv is created on the operator's machine *only* by `00-Stage-Model.ps1` to use `huggingface-hub` and is torn down at the end of the script. The `temp/` ignore is already in `.gitignore` from the strongSwan change.
- **Prerequisites**:
  - `a-infrastructure/01..03` completed (workload RG + VNet exist).
  - `b-shared/02-Deploy-KeyVault.ps1` completed (shared Key Vault exists in access-policy mode).
  - Azure subscription has quota for one `Standard_NC4as_T4_v3` in the chosen region (this is the most likely failure mode for a fresh subscription; documented in README and called out at the start of script 06 with a clear error if `az vm list-usage` shows zero quota).
  - Operator must supply an `-AcmeEmail` (or `DEPLOY_ACME_EMAIL`) for Let's Encrypt account registration.
- **Networking impact**: Adds one subnet to the existing workload VNet (under `core-infrastructure`'s `vnet-llm-workload-<env>-<loc>-001`), one NSG with three inbound allow rules (22/80/443), one set of dual-stack static public IPs. No changes to VNet peering or to existing subnets. No UDRs.
- **Secret material**:
  - New Key Vault secret `vllm-api-key` (256-bit random; rotatable via `Rotate-LlmApiKey.ps1`).
  - The Let's Encrypt account key and certificate live on the VM disk under `/etc/letsencrypt/`; not in Key Vault. (Acceptable per the Mosquitto reference pattern — the cert is publicly issued anyway and re-issued on rebuild.)
- **Cost (informational, not a contract)**: VM ~US$380/month at 24×7 list price; ~US$30–80/month with night auto-shutdown and weekend deallocation. Storage account ~US$0.10/month (one ~5 GB archive blob, LRS). Public IPv4 ~US$3.65/month (Standard SKU, static); IPv6 free. Key Vault secret operations negligible.
- **Threat model accepted by this change**:
  - **Public TCP 22 from the internet** — matches the IoT-repo reference pattern. SSH is key-only (`--generate-ssh-keys`). Operators concerned about scanner noise can replace this with Azure Bastion or JIT in a follow-up; explicitly out of scope here.
  - **Single shared bearer token** — leaks of the token grant full inference access until rotation. Mitigated by `Rotate-LlmApiKey.ps1` and by Key Vault as the source of truth.
  - **Public exposure of the model endpoint** — anyone with the token can run inference and run up the GPU bill. Multi-user authentication and per-key quotas are explicitly deferred to a later `llm-inference-gateway` change introducing LiteLLM.
- **Out of scope (explicit)**:
  - LiteLLM proxy and any form of per-user authentication, quotas, or routing.
  - Multi-model serving (vLLM is one process, one model at a time).
  - Custom domain CNAMEs (the `cloudapp.azure.com` label is the deployed DNS).
  - Bastion / JIT for SSH.
  - Cert material in Key Vault (cert lives on VM disk, certbot manages it).
  - High availability, multi-region, GPU autoscale.
  - Removal of the workload RG itself (handled by `a-infrastructure/91-remove-workload-rg.ps1`); script 91 in this change removes only resources it created.
