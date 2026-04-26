## Context

The repo already has core networking (`a-infrastructure/`) and shared services — Azure Monitor, Key Vault, and an in-flight strongSwan VPN gateway — under `b-shared/`. The workload folder `c-workload/` is empty. The project's stated goal (per `README.md`) is for local AI tools to talk to an open-source LLM hosted in the operator's tenant, but no such workload exists yet.

This change introduces the first inference workload: a single-VM **vLLM** server running **Qwen2.5-Coder-7B-Instruct (AWQ-INT4)** on a T4 GPU, exposed publicly over HTTPS with a Let's Encrypt cert and a shared bearer-token API key.

Surrounding constraints:

- The script style established by `02-Deploy-KeyVault.ps1`, `04-Deploy-GatewaySubnet.ps1`, and `06-Deploy-StrongSwanVm.ps1` (CAF naming, parameter + env-var fallback, `Write-Verbose`, `$ErrorActionPreference='Stop'`, Azure CLI only, idempotent `show`-then-`create`) must be preserved.
- Addressing model from `core-infrastructure` (IPv6 ULA `fdgg:gggg:gggggg:vvss::/64` + IPv4 `10.<gg>.<vv>.<ss*32>/27` derived from `UlaGlobalId` and per-VNet/subnet IDs) is the project-wide pattern; the new subnet inside the workload VNet must conform.
- The reference IoT project's `azure-mosquitto` pattern — Certbot HTTP-01 + native server TLS + cloud-init template substitution — is a known-good blueprint for "public IP, public DNS, Let's Encrypt, server-terminated TLS" and is being deliberately mirrored here.
- The existing shared Key Vault (from `b-shared/02-Deploy-KeyVault.ps1`) is in **access-policy mode**, not RBAC; the same UAMI + access-policy pattern that `b-shared/03-Deploy-VpnIdentity.ps1` established is the natural fit.

## Goals / Non-Goals

**Goals:**

- Stand up a working public OpenAI-compatible HTTPS endpoint serving Qwen2.5-Coder-7B that an operator can point OpenCode (or any OpenAI client) at, end-to-end from a clean subscription state.
- Use vLLM's native `--ssl-*` and `--api-key` flags rather than introducing a reverse proxy. Match the **azure-mosquitto** pattern (server-native TLS + Certbot deploy-hook reload).
- Use Azure-assigned `cloudapp.azure.com` DNS labels — no external DNS registrar, no operator-supplied domain.
- Stage the model in Azure Storage so the VM doesn't depend on Hugging Face being reachable at boot time and so subsequent VM rebuilds are fast.
- Pull all secret material (API key) and bulk material (model archive) from inside the tenant via the VM's user-assigned managed identity. Never embed secrets in cloud-init at substitution time.
- Be re-runnable: every script must be idempotent. Re-running `Deploy-LlmVm.ps1` against an existing VM with unchanged parameters must be a no-op.
- Keep the entire workload deletable via a single `91-Remove-Llm.ps1` script, leaving the workload RG/VNet (owned by `core-infrastructure`) intact.
- Leave a clear seam for the future `llm-inference-gateway` capability (LiteLLM proxy + per-user keys + multi-model routing) to slot in front without rework.

**Non-Goals:**

- LiteLLM proxy, per-user keys, per-key quotas, model routing — deferred to a future change.
- Multi-model serving on the same VM (one vLLM process = one model).
- Custom domain CNAMEs or operator-supplied DNS.
- Bastion / JIT for SSH (SSH is open to the internet, key-only, matching the IoT-repo reference pattern).
- Cert material in Key Vault (cert lives on the VM disk, certbot manages it; same as Mosquitto).
- High availability, multi-region, or GPU autoscale.
- Removing the workload RG itself (handled by `a-infrastructure/91-remove-workload-rg.ps1`); script `91` here removes only resources this change creates.
- Caching the model in a VM image (the VM remains a vanilla Ubuntu LTS + cloud-init).
- Modifying `core-infrastructure` (the workload VNet is consumed read-only; only a new subnet is added inside it).

## Decisions

### D1. vLLM as the inference engine, not Ollama or llama.cpp

**Chosen:** vLLM, pinned to a specific version (e.g. `vllm==0.6.4`), installed in a Python venv at `/opt/vllm/.venv`.

**Alternatives considered:**

- *Ollama* — Lower operational complexity, hot-swappable models, simpler `ollama pull` model management. Rejected because (a) it has no built-in TLS or auth, requiring a Caddy reverse proxy (an extra moving part), and (b) the project's near-term direction is multi-user serving fronted by LiteLLM, where vLLM's continuous-batching / paged-attention is the right backend. Choosing vLLM now avoids a backend swap later.
- *llama.cpp `llama-server`* — Has built-in TLS via cpp-httplib but no built-in auth, so a fronting proxy is needed anyway. Loses on tool-calling maturity vs vLLM's `--tool-call-parser` flag.
- *TGI (Text Generation Inference)* — HF-licensed under Apache for older versions, but recent versions have a more restrictive license and explicitly recommend a reverse proxy for TLS. No advantage.
- *Triton Inference Server* — Enterprise-grade, supports TLS and gRPC, but order-of-magnitude more complex to deploy and tune. Overkill for one model.

**Rationale:** vLLM has the best combination of (a) OpenAI API compliance, (b) tool-calling support that matters for OpenCode, (c) native `--ssl-*` and `--api-key` flags so no proxy is needed, and (d) growth path to multi-user via LiteLLM. The trade-off is heavier startup (~1-2 GB Python+CUDA before model load, ~30-90s cold start) and one-model-per-process rigidity, both acceptable at this stage.

### D2. Native TLS via vLLM `--ssl-*`, certificate via Certbot — no Caddy

**Chosen:** vLLM listens directly on `:443` with `--ssl-certfile /etc/vllm/certs/server.pem --ssl-keyfile /etc/vllm/certs/server.key`. Certbot (standalone HTTP-01) obtains the cert at first boot; a deploy hook copies the cert into `/etc/vllm/certs/` and restarts the `vllm` systemd unit.

**Alternatives considered:**

- *Caddy reverse proxy in front of vLLM (matches azure-leshan)* — Cleanest ACME story, automatic renewal with no hooks, zero-config TLS. Rejected because vLLM already terminates TLS and provides bearer-token auth; Caddy would be a redundant process. The Mosquitto pattern (server-native TLS + Certbot) is the closer analogue when the server can do TLS itself.
- *nginx + certbot* — Same shape as Caddy but worse ergonomics (config + reload hook + certbot timer). Loses on every axis.
- *Self-signed cert* — Trivial to set up but OpenCode (and any browser-based test) rejects untrusted certs without flags. Acceptable only for `-AcmeStaging` dev iteration.
- *Bring-your-own cert from Key Vault* — Adds a renewal pipeline burden. Defer; ACME is fine.

**Rationale:** Removes one process, mirrors the proven `azure-mosquitto` pattern, and pushes responsibility for TLS into the inference engine where the configuration is most discoverable.

### D3. Certbot HTTP-01 standalone, deploy hook restarts vLLM

**Chosen:** First boot:

```sh
systemctl stop vllm           # vLLM doesn't bind 80, but be explicit
certbot certonly --standalone --preferred-challenges http \
    --cert-name vllm-cert -d <fqdn> -n --agree-tos -m <email> \
    [--test-cert]   # only when -AcmeStaging
RENEWED_LINEAGE=/etc/letsencrypt/live/vllm-cert \
    sh /etc/letsencrypt/renewal-hooks/deploy/10-vllm-restart.sh
systemctl start vllm
```

Deploy hook (`/etc/letsencrypt/renewal-hooks/deploy/10-vllm-restart.sh`):

```sh
#!/bin/sh
SOURCE_DIR=/etc/letsencrypt/live/vllm-cert
CERTIFICATE_DIR=/etc/vllm/certs
if [ "${RENEWED_LINEAGE}" = "${SOURCE_DIR}" ]; then
    cp ${RENEWED_LINEAGE}/fullchain.pem ${CERTIFICATE_DIR}/server.pem
    cp ${RENEWED_LINEAGE}/privkey.pem  ${CERTIFICATE_DIR}/server.key
    chown vllm: ${CERTIFICATE_DIR}/server.pem ${CERTIFICATE_DIR}/server.key
    chmod 0600 ${CERTIFICATE_DIR}/server.pem ${CERTIFICATE_DIR}/server.key
    systemctl restart vllm
fi
```

Renewal happens automatically via the `certbot.timer` systemd unit shipped with the certbot Debian package. The deploy hook fires on every successful renewal.

**Alternatives considered:**

- *`systemctl reload vllm` instead of `restart`* — vLLM does not have a documented SIGHUP cert-reload behaviour; a SIGHUP is treated as terminate by default for Python processes. Restart is correct here. Acceptable downtime: ~30-60s every 60 days.
- *DNS-01 challenge* — Would let us run without inbound 80 and would support wildcard certs. Requires a DNS provider plugin and access tokens; `cloudapp.azure.com` is not configurable by the operator anyway. HTTP-01 is the right fit.
- *`--standalone` competing with vLLM for port 80* — vLLM never binds 80; only 443. No conflict.

**Rationale:** Mirrors the Mosquitto reference pattern verbatim, with `restart` instead of `pkill -HUP` because vLLM's signal handling differs.

### D4. Capability binding (`cap_net_bind_service`) so vLLM binds 443 without root

**Chosen:** After `pip install vllm`, cloud-init runs:

```sh
setcap 'cap_net_bind_service=+ep' /opt/vllm/.venv/bin/python3*
```

The `vllm` systemd unit then runs as a non-root `vllm` system user but can still bind to port 443.

**Alternatives considered:**

- *Run vLLM as root* — Bad practice; nothing about vLLM requires root.
- *Listen on a high port (e.g. 8443) and add a kernel-level redirect (`iptables -t nat … REDIRECT --to-port 8443`)* — Adds a hidden moving part; capabilities are the standard answer.
- *Run vLLM behind a Caddy/nginx that holds 443* — Already rejected in D2.

**Rationale:** Standard Linux mechanism for non-root low-port binding, no hidden indirection, and the capability is set on the venv's specific Python binary so it doesn't grant the privilege system-wide.

### D5. Model staged in Azure Storage, not pulled from Hugging Face on the VM

**Chosen:** A separate one-off script `00-Stage-Model.ps1` runs on the operator's machine. It:

1. Creates a Python venv under `./temp/hf-stage/` and installs `huggingface-hub`.
2. Downloads `Qwen/Qwen2.5-Coder-7B-Instruct-AWQ` from Hugging Face into `./temp/models/qwen2.5-coder-7b-awq/`.
3. Tars + zstd-compresses the result into `./temp/qwen2.5-coder-7b-awq.tar.zst`.
4. Uploads the archive to a private container `models` in the workload storage account, blob name `qwen2.5-coder-7b-awq.tar.zst`.

Idempotency:
- Skips download if the local model directory already contains the expected `config.json` + at least one `*.safetensors` file (HF download already does this internally; we just don't delete `./temp/models/` between runs).
- Skips upload if `az storage blob show` reports the blob exists with a matching `Content-MD5`.

The blob is reachable only via the storage account's managed-identity-authorised data plane; no SAS or anonymous access. Cloud-init authenticates with the VM's UAMI to download:

```sh
az login --identity --username "$UAMI_CLIENT_ID"
az storage blob download \
    --account-name <storage> \
    --container-name models \
    --name qwen2.5-coder-7b-awq.tar.zst \
    --file /tmp/model.tar.zst \
    --auth-mode login
zstd -d /tmp/model.tar.zst -o /tmp/model.tar
tar -x -f /tmp/model.tar -C /opt/models
rm /tmp/model.tar /tmp/model.tar.zst
```

The UAMI is granted `Storage Blob Data Reader` scoped to the container by `04-Deploy-LlmIdentity.ps1`. This is a data-plane RBAC role, not a management-plane one — Contributor can assign it because the scope is the storage container, owned by the workload RG which the operator already controls.

**Alternatives considered:**

- *Pull from Hugging Face on first boot* — Simpler. Rejected because (a) bootstrap takes ~5-10 min on the VM (vs. one-time on the operator's machine), (b) creates a deploy-time dependency on HF reachability and on whatever HF rate-limits apply to anonymous downloads of large repos, (c) doesn't survive subscription-internal deploys when egress is restricted. Staging in Azure Storage is the closer fit to the project's "stays in your tenant" thesis.
- *Bake the model into a custom VM image* — Fastest boot, but introduces image-build pipeline (Packer or `az image create`) and image lifecycle. Defer.
- *Mount the storage container via NFS / blobfuse2* — Works but adds a runtime dependency on the storage account being reachable for every model load (vLLM only reads the model at startup, so the marginal benefit is zero).
- *SAS URL substituted into cloud-init by the deploy script* — Was the v1 plan; rejected because (a) SAS tokens are bearer credentials in cloud-init `--custom-data`, which is visible via Instance Metadata Service to any process on the VM, and (b) UAMI + RBAC is more aligned with how the rest of the repo handles in-tenant fetches.

**Rationale:** Operator pays the download cost once, Azure-internal bandwidth is fast and free, the VM's only deploy-time dependency is its own tenant, and authentication is consistent with how cloud-init fetches the API key.

### D6. UAMI + Key Vault access policy + Storage RBAC (matches strongSwan pattern)

**Chosen:** `04-Deploy-LlmIdentity.ps1` creates a user-assigned managed identity `id-llm-vllm-<env>-001` in the workload RG. It grants:

- `get, list` on **secrets** in the **shared Key Vault** via `az keyvault set-policy --object-id <uami-principalId>` (matches access-policy mode).
- `Storage Blob Data Reader` scoped to `https://<storage>.blob.core.windows.net/models` via `az role assignment create` (data-plane RBAC, allowed within Contributor on the storage account scope).

`06-Deploy-LlmVm.ps1` binds the UAMI at VM-create time (`--assign-identity <uami-resourceId>`). Cloud-init's `runcmd` logs in once with the UAMI:

```sh
az login --identity --username "$UAMI_CLIENT_ID"
```

then performs the API-key fetch and the model archive download. The `--username` form is required because a VM can have multiple identities; we want the explicit one.

The UAMI's `clientId` is substituted into cloud-init via `#INIT_UAMI_CLIENT_ID#`; not a secret, just a GUID that identifies which identity to use.

**Alternatives considered:**

- *System-assigned managed identity* — Same race-condition objection as the strongSwan design (D4 of `configure-strongswan-vm/design.md`): SA-MI only materialises after `az vm create` returns, forcing a permission grant just before cloud-init's first `az login --identity`. Pre-creating a UAMI avoids this entirely.
- *RBAC on Key Vault* — The shared Key Vault is in access-policy mode (per `b-shared/02-Deploy-KeyVault.ps1`); switching it to RBAC mode would also require Owner permissions for the operator. Stay in access-policy mode for Key Vault, RBAC for storage (where it's fine).
- *Store the API key in cloud-init `--custom-data`* — Visible to every process on the VM via IMDS. Rejected.

**Rationale:** Mirrors the strongSwan pattern that already works in this repo, fits the operator's Contributor-only permissions, and keeps cloud-init linear.

### D7. Subnet inside the existing workload VNet, dedicated NSG, three inbound allow rules

**Chosen:** A new subnet `snet-llm-vllm-<env>-<location>-001` is added inside the existing `vnet-llm-workload-<env>-<location>-001` (created by `a-infrastructure/03`). The subnet is a `/64` IPv6 + `/27` IPv4 (matching the project's per-subnet sizing).

`<vv>` (VNet ID) is `0300` (the workload VNet's ID, fixed by `core-infrastructure`).
`<ss>` (subnet ID inside the workload VNet) is `01` for this subnet.

Subnet prefixes (using `core-infrastructure`'s formulae):

| Layer | Prefix |
|---|---|
| IPv6 | `fd<gg>:<gggg>:<gggggg>:0301::/64` |
| IPv4 | `10.<gg>.3.32/27` |

A new NSG `nsg-llm-vllm-<env>-001` is associated to the subnet with three inbound allow rules:

| Priority | Name | Direction | Protocol | Dest port | Source | Action |
|---|---|---|---|---|---|---|
| 1000 | `AllowSshInbound` | Inbound | TCP | 22 | `*` | Allow |
| 1010 | `AllowHttpInbound` | Inbound | TCP | 80 | `*` | Allow |
| 1020 | `AllowHttpsInbound` | Inbound | TCP | 443 | `*` | Allow |

Default deny-inbound from Azure's NSG default chain handles everything else. No outbound rules added (default allow-internet outbound is fine — it's needed for `apt`, `pip`, ACME, NVIDIA repos).

**Alternatives considered:**

- *Restrict source to operator's IP* — Tried in plan; rejected because Let's Encrypt's HTTP-01 challenge requires the validation server to be reachable from LE's validators (which come from many IPs and are not published as a stable list).
- *Restrict 22 to operator's IP* — Possible but fragile (home IPs change). Match the IoT-repo pattern (open 22, key-only auth).
- *Use `core-infrastructure`'s existing rules for the workload subnet* — Rejected: a workload-specific NSG keeps the LLM VM's posture independently revisable without affecting any future workloads in the same VNet.

**Rationale:** Matches `core-infrastructure`'s subnet/addressing scheme, keeps NSG scope small and revisable, and accepts the same SSH-open-to-internet posture used in the IoT reference.

### D8. Public IPs: dual-stack Standard SKU, static, with deterministic DNS labels

**Chosen:** `05-Deploy-LlmPublicIp.ps1` creates:

- `pip-llm-vllm-<env>-<location>-001` — IPv6, Standard, static, DNS label `llm-<orgid>-<env>` → `llm-<orgid>-<env>.<location>.cloudapp.azure.com`.
- `pipv4-llm-vllm-<env>-<location>-001` — IPv4, Standard, static, DNS label `llm-<orgid>-<env>-ipv4` → `llm-<orgid>-<env>-ipv4.<location>.cloudapp.azure.com`.

`<orgid>` = `0x` + first 4 hex of the subscription id, matching the project-wide pattern in `AGENTS.md` and `core-infrastructure`.

The IPv6 FQDN is the **primary** name and is what the Let's Encrypt cert is issued for. The IPv4 FQDN is included as an additional `subjectAltName` (`-d <ipv6-fqdn> -d <ipv4-fqdn>`) so OpenCode can connect over either.

**Alternatives considered:**

- *Single IP* — Azure VMs require an IPv4 (Azure platform constraint, matched in `azure-leshan`). Both is right.
- *Operator-supplied DNS* — Rejected per the v3 plan: requires the operator to own a domain and create A/AAAA records, doubling the prerequisites for no real gain over `cloudapp.azure.com`.
- *Dynamic IP allocation* — Static is required so the DNS label doesn't drift across stop/start cycles. Standard SKU is required to allow a NIC to attach an IPv6 PIP on Azure.

**Rationale:** Matches the `azure-leshan` and `azure-mosquitto` patterns, free DNS, no external registrar dependency, and Let's Encrypt issues against `cloudapp.azure.com` with no special handling.

### D9. VM SKU: `Standard_NC4as_T4_v3` with NVIDIA driver VM extension

**Chosen:** Single VM, `Standard_NC4as_T4_v3` (4 vCPU, 28 GB RAM, 1× T4 16 GB), Ubuntu 22.04 LTS, NVIDIA GPU Driver Linux extension applied at create time.

VM disk: default OS disk only (no data disk). The model archive (`/opt/models/qwen2.5-coder-7b-awq/`) lives on the OS disk; ~10 GB after extraction. OS disk default size (~30 GB) is sufficient.

Auto-shutdown configured via `az vm auto-shutdown` at a fixed UTC time (default `0900` UTC = 19:00 in Brisbane, matching `azure-leshan`).

**Alternatives considered:**

- *`Standard_NC8as_T4_v3` (1× T4, 8 vCPU)* — More CPU; not bottlenecked by CPU at this workload. Costs more for nothing.
- *`Standard_NC6s_v3` (1× V100 16 GB)* — Older, no longer the cheapest GPU per region; T4 is the modern dev-tier choice.
- *`Standard_NV6ads_A10_v5` (1/6× A10)* — Partitioned A10. Cheaper, but A10 is overkill for 7B; T4 has been validated for AWQ-INT4 7B at 32K context.
- *CPU-only VM with llama.cpp* — Rejected in earlier planning; OpenCode agent loops are too chatty for CPU inference.
- *Spot VMs* — Not supported on most NC SKUs; would also break `Start-/Stop-LlmVm.ps1` semantics.

**Rationale:** Smallest currently-available T4 SKU on Azure, matches the model size, has documented quota availability in mainstream regions, supports the NVIDIA driver extension. The trade-off is GPU quota (often zero on a fresh subscription); the deploy script checks quota up-front and emits a clear error if zero.

### D10. AWQ-INT4 quantisation, served by vLLM

**Chosen:** `Qwen/Qwen2.5-Coder-7B-Instruct-AWQ` (Apache-2.0, ~5 GB), passed to vLLM via `--model /opt/models/qwen2.5-coder-7b-awq` and `--served-model-name qwen2.5-coder-7b`.

vLLM detects AWQ from the model's `config.json` and selects the AWQ kernel automatically; no explicit `--quantization` flag needed in current vLLM versions.

Tool calling: `--tool-call-parser hermes --enable-auto-tool-choice`. Qwen2.5-Coder uses Hermes-style tool tokens.

Context length: `--max-model-len 32768`. Qwen2.5-Coder-7B's training context is 32K; vLLM defaults can reserve more KV cache than fits on a T4 unless capped.

**Alternatives considered:**

- *GPTQ-INT4* — Similar quality and VRAM, slightly less common in vLLM's published benchmarks. AWQ is the safer default for this size.
- *FP16 unquantised* — ~14 GB VRAM; just barely fits T4 with very reduced context. Risky on this SKU.
- *GGUF Q4_K_M* — vLLM's GGUF support is recent and less battle-tested; the Ollama/llama.cpp ecosystem is the natural home for GGUF.
- *Smaller Qwen variant (3B / 1.5B / 0.6B)* — Tool-calling reliability degrades sharply. 7B is the smallest size that works well as an OpenCode agent.

**Rationale:** Best quality at 4-bit, native vLLM support, proven on T4, comfortable with 32K context.

### D11. Six (+ utility) PowerShell scripts, sequential numeric ordering, flat layout

**Chosen:** Scripts live directly in `c-workload/` with numeric prefixes:

| # | Script | Role |
|---|---|---|
| 00 | `00-Stage-Model.ps1` | One-time: download from HF, upload to blob (idempotent) |
| 01 | `01-Deploy-LlmStorage.ps1` | Storage account + private container |
| 02 | `02-Deploy-LlmSubnet.ps1` | Subnet + NSG inside existing workload VNet |
| 03 | `03-Deploy-LlmKeyVaultSecret.ps1` | Generates and stores `vllm-api-key` in shared Key Vault |
| 04 | `04-Deploy-LlmIdentity.ps1` | UAMI + KV access policy + storage RBAC |
| 05 | `05-Deploy-LlmPublicIp.ps1` | Static dual-stack PIPs with `cloudapp.azure.com` DNS labels |
| 06 | `06-Deploy-LlmVm.ps1` | NIC, VM, NVIDIA extension, auto-shutdown, custom-data cloud-init |
| 07 | `07-Test-LlmEndpoint.ps1` | `/v1/models` + tool-call smoke test |
| 91 | `91-Remove-Llm.ps1` | Reverse-order teardown of resources created by 01-06 |
| — | `Stop-LlmVm.ps1`, `Start-LlmVm.ps1`, `Rotate-LlmApiKey.ps1` | Operational utilities |

`c-workload/data/vllm-cloud-init.txt` is the cloud-init template; runtime substitution writes `c-workload/temp/vllm-cloud-init.txt~` (gitignored).

**Alternatives considered:**

- *Nested folder `c-workload/azure-vllm/`* — Mirrors the IoT repo's `azure-leshan/`/`azure-mosquitto/` convention. Considered and rejected for now (per operator preference): the project has only one workload today; flat-with-numeric-prefixes matches `a-infrastructure/` and `b-shared/`. Re-folder if a second workload is added.
- *Combine scripts (e.g. fold storage + subnet + identity into a single Deploy-Llm.ps1)* — Rejected: each step has a different lifecycle and a different Azure scope. Splitting also means rotating the API key doesn't redeploy the VM.

**Rationale:** Matches the established style of the repo (`a-infrastructure/01-…`, `b-shared/02-…`), makes the dependency order self-documenting, and lets each step be re-run independently.

### D12. cloud-init template substitution

The deploy script substitutes these tokens into a copy of `c-workload/data/vllm-cloud-init.txt` written to `c-workload/temp/vllm-cloud-init.txt~`:

| Token | Substituted value |
|---|---|
| `#INIT_HOST_NAME#` | Primary FQDN (IPv6 `cloudapp.azure.com` label) |
| `#INIT_HOST_NAME_IPV4#` | IPv4 FQDN, used as additional ACME `-d` flag |
| `#INIT_KEY_VAULT_NAME#` | Name of the shared Key Vault |
| `#INIT_API_KEY_SECRET_NAME#` | `vllm-api-key` |
| `#INIT_STORAGE_ACCOUNT#` | Workload storage account name |
| `#INIT_MODEL_BLOB_NAME#` | `qwen2.5-coder-7b-awq.tar.zst` |
| `#INIT_UAMI_CLIENT_ID#` | `clientId` of the UAMI from script 04 |
| `#INIT_CERT_EMAIL#` | Operator-supplied `-AcmeEmail` (or `DEPLOY_ACME_EMAIL`) |
| `#INIT_ACME_STAGING_FLAG#` | Empty by default; `--test-cert` when `-AcmeStaging` is passed |
| `#INIT_VLLM_VERSION#` | Pinned vLLM version (e.g. `0.6.4`) |
| `#INIT_SERVED_MODEL_NAME#` | `qwen2.5-coder-7b` |

No secrets are substituted into cloud-init: the API key is fetched at boot from Key Vault using the UAMI; the model archive is fetched at boot from Storage using the UAMI.

### D13. systemd unit for vLLM, env-file for the API key

**Chosen:** `/etc/systemd/system/vllm.service`:

```ini
[Unit]
Description=vLLM OpenAI-compatible server
After=network-online.target
Wants=network-online.target

[Service]
User=vllm
Group=vllm
EnvironmentFile=/etc/vllm/vllm.env
ExecStart=/opt/vllm/.venv/bin/python -m vllm.entrypoints.openai.api_server \
    --host :: \
    --port 443 \
    --ssl-certfile /etc/vllm/certs/server.pem \
    --ssl-keyfile  /etc/vllm/certs/server.key \
    --api-key      ${VLLM_API_KEY} \
    --model        /opt/models/qwen2.5-coder-7b-awq \
    --served-model-name qwen2.5-coder-7b \
    --tool-call-parser hermes \
    --enable-auto-tool-choice \
    --max-model-len 32768
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

`/etc/vllm/vllm.env` is `0600`, owned by `vllm:vllm`, contains `VLLM_API_KEY=<secret>` (and `HF_HOME=/opt/models/.cache` to keep any vLLM-side downloads contained). Cloud-init writes it at first boot from the Key Vault fetch:

```sh
VLLM_API_KEY=$(az keyvault secret show \
    --vault-name "$KV_NAME" --name vllm-api-key \
    --query value -o tsv)
install -m 0600 -o vllm -g vllm /dev/null /etc/vllm/vllm.env
printf 'VLLM_API_KEY=%s\nHF_HOME=/opt/models/.cache\n' "$VLLM_API_KEY" \
    > /etc/vllm/vllm.env
```

`Rotate-LlmApiKey.ps1` regenerates the secret in Key Vault, then runs the equivalent `az vm run-command invoke` to rewrite `/etc/vllm/vllm.env` and `systemctl restart vllm`.

**Rationale:** Single source of truth for the key (Key Vault), in-process env-var consumption matches vLLM's documented `--api-key ${VAR}` pattern, and rotation needs no VM rebuild.

### D14. Smoke test contract (`07-Test-LlmEndpoint.ps1`)

The test fetches the API key from Key Vault and the FQDN from the public IP, then makes two HTTPS calls:

1. `GET https://<fqdn>/v1/models` with `Authorization: Bearer <key>` — asserts 200 and that the response `data[].id` array contains `qwen2.5-coder-7b`.
2. `POST https://<fqdn>/v1/chat/completions` with a single tool definition (`get_weather(location: string)`) and a user message `"what's the weather in London?"` — asserts 200 and that `choices[0].message.tool_calls` is a non-empty array whose first entry has `function.name == "get_weather"`.

Both calls go via `Invoke-RestMethod` with default certificate validation (so a real Let's Encrypt cert is required to pass without flags; with `-AcmeStaging` the script emits a warning and uses `-SkipCertificateCheck`).

The script exits 0 on both passes, non-zero with diagnostic output on any failure.

**Rationale:** Validates the only two capabilities that matter for OpenCode: that the OpenAI-compatible endpoint serves the model under the expected name, and that tool-calling round-trips correctly. Anything else is implementation detail.

### D15. Naming and tagging

Naming pattern (matches `core-infrastructure`):

| Resource | Pattern | Example |
|---|---|---|
| Storage account | `stllm<orgid><env>001` | `stllm0xacc5dev001` |
| Storage container | `models` | `models` |
| Subnet | `snet-llm-vllm-<env>-<location>-001` | `snet-llm-vllm-dev-australiaeast-001` |
| NSG | `nsg-llm-vllm-<env>-001` | `nsg-llm-vllm-dev-001` |
| Key Vault secret | `vllm-api-key` | `vllm-api-key` |
| User-assigned identity | `id-llm-vllm-<env>-001` | `id-llm-vllm-dev-001` |
| Public IPv6 | `pip-llm-vllm-<env>-<loc>-001` | `pip-llm-vllm-dev-australiaeast-001` |
| Public IPv4 | `pipv4-llm-vllm-<env>-<loc>-001` | `pipv4-llm-vllm-dev-australiaeast-001` |
| IPv6 DNS label | `llm-<orgid>-<env>` | `llm-0xacc5-dev` |
| IPv4 DNS label | `llm-<orgid>-<env>-ipv4` | `llm-0xacc5-dev-ipv4` |
| NIC | `nic-01-vmllmvllm001-<env>-001` | `nic-01-vmllmvllm001-dev-001` |
| NIC IP config (extra) | `ipc-01-vmllmvllm001-<env>-001` | `ipc-01-vmllmvllm001-dev-001` |
| VM | `vmllmvllm001` | `vmllmvllm001` |
| OS disk | `osdiskvmllmvllm001` | `osdiskvmllmvllm001` |

Tags (CAF + repo conventions, identical to `core-infrastructure`):

| Tag | Value |
|---|---|
| `WorkloadName` | `llm` |
| `ApplicationName` | `llm-vllm` |
| `DataClassification` | `Non-business` |
| `Criticality` | `Low` |
| `BusinessUnit` | `IT` |
| `Env` | `<Environment>` |

## Risks / Trade-offs

- **[GPU quota = zero on fresh subscriptions]** → `06-Deploy-LlmVm.ps1` runs `az vm list-usage` at the start and emits a clear message (`"Subscription has 0 quota for standardNCASv3Family in <region>; request a quota increase via the Azure portal before re-running"`) if zero. README documents the quota-request flow.
- **[vLLM version drift]** → vLLM's CLI flags change between minor versions (notably `--tool-call-parser` and quantisation flags). Mitigation: pin to a specific version (`--vllm-version 0.6.4` parameter, default in script 06; pinned in cloud-init's `pip install vllm==<version>`). Updating is a deliberate operator action.
- **[`Qwen/Qwen2.5-Coder-7B-Instruct-AWQ` repo could move]** → `00-Stage-Model.ps1` fails loudly via `huggingface-hub`'s `RepositoryNotFoundError`. README documents how to override the source repo with `-ModelRepoId`.
- **[Let's Encrypt rate limits during dev iteration]** → 5 duplicate certs per `cloudapp.azure.com` subdomain per week. Mitigation: `-AcmeStaging` switch on `06-Deploy-LlmVm.ps1` (default off, prod cert by default).
- **[vLLM cert reload requires restart, not reload]** → ~30-60s downtime once every ~60 days during cert renewal. Acceptable for a single-user dev endpoint.
- **[Public TCP 22 from internet]** → Accepted; matches the IoT-repo reference. Key-only auth (`--generate-ssh-keys`).
- **[Single shared bearer token]** → A token leak grants full inference access until rotated. Mitigations: rotation via `Rotate-LlmApiKey.ps1` (no rebuild), Key Vault as the source of truth, future LiteLLM proxy will replace this with per-user keys.
- **[Port 80 used briefly during cert issuance/renewal]** → vLLM never binds 80, so no conflict; certbot standalone takes 80 transiently. Documented; NSG must allow 80 inbound.
- **[Bound IPv6 listener on Linux accepts IPv4 via v4-mapped]** → vLLM uses Python's `socket` defaults; `--host ::` binds dual-stack as long as `/proc/sys/net/ipv6/bindv6only` is 0 (Ubuntu default). Verified by smoke test (which connects via both FQDNs when `-TestIpv4` flag is set).
- **[Cloud-init failures are silent until polled]** → `06-Deploy-LlmVm.ps1` runs `az vm run-command invoke -- "cloud-init status --wait"` after `az vm create` returns and fails the deployment if the final status is not `done`. Logs from `/var/log/cloud-init-output.log` are streamed to the operator on failure.
- **[`Storage Blob Data Reader` propagation]** → Data-plane RBAC role assignments can take 30–120s to propagate. Cloud-init wraps the model download in a retry loop (cap ~3 minutes).
- **[Storage account egress cost in cross-region builds]** → Within-region (storage account + VM in the same Azure region) is free. README documents "stage in same region as VM" explicitly.
- **[Model archive ~5 GB on the OS disk]** → Default OS disk (~30 GB) has headroom but not a lot. If a future model is much larger, add a data disk; flagged for follow-up.
- **[Running `Rotate-LlmApiKey.ps1` while vLLM is mid-request]** → Existing connections may receive a 401 on subsequent calls until the client re-reads the key. Acceptable for a dev endpoint.

## Migration Plan

This is the first workload in `c-workload/`; there is no prior version to migrate from.

1. Merge proposal + design + specs + tasks.
2. Operator confirms T4 quota in their region (one-time, may take days for a new subscription).
3. Operator runs in order:
   - `a-infrastructure/01..03` (RGs + VNets + peering)
   - `b-shared/01-02` (Azure Monitor + Key Vault)
   - `c-workload/00-Stage-Model.ps1` (one-time, ~10 min on a good connection)
   - `c-workload/01-Deploy-LlmStorage.ps1`
   - `c-workload/02-Deploy-LlmSubnet.ps1`
   - `c-workload/03-Deploy-LlmKeyVaultSecret.ps1`
   - `c-workload/04-Deploy-LlmIdentity.ps1`
   - `c-workload/05-Deploy-LlmPublicIp.ps1`
   - `c-workload/06-Deploy-LlmVm.ps1` (the long one — VM create + cloud-init ~10–15 min)
   - `c-workload/07-Test-LlmEndpoint.ps1` (the validation step)
4. Operator copies the printed FQDN + retrieves the API key from Key Vault, configures OpenCode per `docs/OpenCode-vllm-config.md`.
5. Daily ops:
   - `Stop-LlmVm.ps1` at end of day, `Start-LlmVm.ps1` next morning (or rely on auto-shutdown + manual start).
6. Rollback / partial teardown:
   - To rotate the API key: `Rotate-LlmApiKey.ps1`. No VM rebuild.
   - To rebuild the VM only: `91-Remove-Llm.ps1 -Scope Vm`, then `06-Deploy-LlmVm.ps1`. Storage/identity/secret/PIP/subnet preserved.
   - Full LLM workload teardown: `91-Remove-Llm.ps1`. Workload RG + VNet remain (owned by `core-infrastructure`).
7. Future replacement (out of scope): introduce LiteLLM as a separate VM or container in front; switch the public DNS label to point at LiteLLM; vLLM moves to a private endpoint inside the VNet.

## Open Questions

- **Should `vllm-api-key` be rotated on a schedule rather than on-demand?** Out of scope here. A future change could introduce a Key Vault rotation policy + deploy hook.
- **Should the storage account use a Private Endpoint instead of public-with-RBAC?** Functionally cleaner but adds DNS-zone work. Defer; current posture is acceptable because access requires a managed-identity token, not a SAS.
- **Should we surface the vLLM Prometheus metrics endpoint?** vLLM exposes `/metrics`; we currently leave it on the same `:443` listener (so it's behind the bearer token via vLLM's `--api-key`). A future Azure Monitor / Managed Grafana integration is possible.
- **Should auto-shutdown be configurable per-environment via parameter or always 19:00 local?** Match `azure-leshan` for consistency: `-ShutdownUtc` parameter with `0900` UTC default; operator overrides for non-AEST timezones.
- **Should `setcap` be run on a stable Python symlink rather than the venv's `python3*`?** The venv pins to a specific Python minor version (3.10, 3.11, …). If Ubuntu's package manager upgrades the underlying interpreter, the venv keeps a copy; capability survives. Confirmed safe; documented in the script comment.
- **Should we ship a second model concurrently?** No — vLLM is one model per process. Multi-model is a LiteLLM-era concern.
