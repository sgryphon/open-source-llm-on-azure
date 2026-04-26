## Context

The repo already has core networking (`a-infrastructure/`) and shared services — Azure Monitor, Key Vault, and an in-flight strongSwan VPN gateway — under `b-shared/`. The workload folder `c-workload/` is empty. The project's stated goal (per `README.md`) is for local AI tools to talk to an open-source LLM hosted in the operator's tenant, but no such workload exists yet.

This change introduces the first inference workload: a single-VM **vLLM** server running **Qwen2.5-Coder-7B-Instruct (AWQ-INT4)** on a T4 GPU, exposed publicly over HTTPS with a Let's Encrypt cert and a shared bearer-token API key. The model bytes (~5.5 GB) are held on a **persistent Managed Disk** that survives VM rebuilds; the operator's workstation never holds them, and no Azure Storage account exists in the design.

Surrounding constraints:

- The script style established by `02-Deploy-KeyVault.ps1`, `04-Deploy-GatewaySubnet.ps1`, and `06-Deploy-StrongSwanVm.ps1` (CAF naming, parameter + env-var fallback, `Write-Verbose`, `$ErrorActionPreference='Stop'`, Azure CLI only, idempotent `show`-then-`create`) must be preserved.
- Addressing model from `core-infrastructure` (IPv6 ULA `fdgg:gggg:gggggg:vvss::/64` + IPv4 `10.<gg>.<vv>.<ss*32>/27` derived from `UlaGlobalId` and per-VNet/subnet IDs) is the project-wide pattern; the new subnet inside the workload VNet must conform.
- The reference IoT project's `azure-mosquitto` pattern — Certbot HTTP-01 + native server TLS + cloud-init template substitution — is a known-good blueprint for "public IP, public DNS, Let's Encrypt, server-terminated TLS" and is being deliberately mirrored here.
- The existing shared Key Vault (from `b-shared/02-Deploy-KeyVault.ps1`) is in **access-policy mode**, not RBAC; the same UAMI + access-policy pattern that `b-shared/03-Deploy-VpnIdentity.ps1` established is the natural fit.
- No removal scripts inside `c-workload/`. RG-level teardown is owned by `a-infrastructure/`. Intra-workload reverse operations are limited to detach helpers in `util/`.

## Goals / Non-Goals

**Goals:**

- Stand up a working public OpenAI-compatible HTTPS endpoint serving Qwen2.5-Coder-7B that an operator can point OpenCode (or any OpenAI client) at, end-to-end from a clean subscription state.
- Use vLLM's native `--ssl-*` and `--api-key` flags rather than introducing a reverse proxy. Match the **azure-mosquitto** pattern (server-native TLS + Certbot deploy-hook reload).
- Use Azure-assigned `cloudapp.azure.com` DNS labels — no external DNS registrar, no operator-supplied domain.
- Hold the model on a persistent Managed Disk independent of the VM, so deleting and recreating the VM does not require re-downloading the model.
- Keep all model bytes off the operator's workstation: the Hugging Face download happens *inside* the VM via `az vm run-command invoke`, triggered by an operator-side script.
- Pull all secret material (API key) from inside the tenant via the VM's user-assigned managed identity. Never embed secrets in cloud-init at substitution time.
- Be re-runnable: every script must be idempotent. Re-running `06-Deploy-LlmVm.ps1` against an existing VM with unchanged parameters must be a no-op. Re-running `util/Download-LlmModelToDisk.ps1` when the model is already on the disk must be a no-op.
- Leave a clear seam for the future `llm-inference-gateway` capability (LiteLLM proxy + per-user keys + multi-model routing) to slot in front without rework.

**Non-Goals:**

- LiteLLM proxy, per-user keys, per-key quotas, model routing — deferred to a future change.
- Multi-model serving on the same VM (one vLLM process = one model).
- Custom domain CNAMEs or operator-supplied DNS.
- Bastion / JIT for SSH (SSH is open to the internet, key-only, matching the IoT-repo reference pattern).
- Cert material in Key Vault (cert lives on the VM disk, certbot manages it; same as Mosquitto).
- High availability, multi-region, or GPU autoscale.
- Any `9x-Remove-*.ps1` script inside `c-workload/`. RG-level teardown of the workload RG is the responsibility of `a-infrastructure/` (an `a-infrastructure/9x-Remove-WorkloadRg.ps1` may be added in a future change; today, `az group delete --name rg-llm-workload-<env>-001` is the operator's escape hatch).
- Azure Storage / Blob staging. The earlier draft of this design used a Blob container as a canonical model store; that is dropped. The data disk is the canonical store; if it is lost, Hugging Face is the recovery source.
- Caching the model in a custom VM image.
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
    --cert-name vllm-cert -d <fqdn-v6> -d <fqdn-v4> -n --agree-tos -m <email> \
    [--test-cert]   # only when -AcmeStaging
RENEWED_LINEAGE=/etc/letsencrypt/live/vllm-cert \
    sh /etc/letsencrypt/renewal-hooks/deploy/10-vllm-restart.sh
# vllm.service is enabled but not started here — its ConditionPathExists
# guard prevents start until the model is loaded onto the data disk.
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

Renewal happens automatically via the `certbot.timer` systemd unit shipped with the certbot Debian package. The deploy hook fires on every successful renewal. `systemctl restart vllm` is a no-op while the unit's `ConditionPathExists` is unsatisfied, and a real restart once the model is loaded.

**Alternatives considered:**

- *`systemctl reload vllm` instead of `restart`* — vLLM does not have a documented SIGHUP cert-reload behaviour; SIGHUP is treated as terminate by default for Python processes. Restart is correct here. Acceptable downtime: ~30-60s every 60 days.
- *DNS-01 challenge* — Would let us run without inbound 80 and would support wildcard certs. Requires a DNS provider plugin and access tokens; `cloudapp.azure.com` is not configurable by the operator anyway. HTTP-01 is the right fit.

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

### D5. Model held on a persistent Managed Disk; downloaded on demand from Hugging Face

**Chosen:** A separate Managed Disk `disk-llm-vllm-models-<env>-001` (Standard SSD, 8 GiB, E2 tier) is created by `05-Deploy-LlmDataDisk.ps1` as a standalone resource. `06-Deploy-LlmVm.ps1` attaches it at LUN 0 via `--attach-data-disks <disk-id>`. Cloud-init formats the disk with ext4 (only if `blkid` reports no filesystem) using `mkfs.ext4 -L llm-models`, then persistently mounts it at `/opt/models` via an `/etc/fstab` entry keyed on `LABEL=llm-models` (mount option `nofail` so a missing disk does not block boot).

After the VM is up, the operator runs `util/Download-LlmModelToDisk.ps1`, which uses `az vm run-command invoke` to execute an inline shell script on the VM:

```sh
set -euo pipefail
TARGET=/opt/models/qwen2.5-coder-7b-awq
if [ -f "$TARGET/config.json" ]; then
    echo "model already present, skipping"
    exit 0
fi
mkdir -p "$TARGET"
/opt/vllm/.venv/bin/pip install -q huggingface-hub
/opt/vllm/.venv/bin/huggingface-cli download \
    Qwen/Qwen2.5-Coder-7B-Instruct-AWQ \
    --local-dir "$TARGET" \
    --local-dir-use-symlinks False
chown -R vllm:vllm /opt/models
systemctl start vllm
systemctl is-active --quiet vllm \
    || (journalctl -u vllm --since "2 min ago" -n 200; exit 1)
```

The operator's workstation never holds the model bytes. The VM's outbound internet (already needed for `apt`, `pip`, ACME, NVIDIA repos) is the egress path.

**Idempotency:** the script short-circuits when `/opt/models/qwen2.5-coder-7b-awq/config.json` already exists.

**Detach-before-rebuild:** when the operator wants to rebuild the VM keeping the data, `util/Detach-LlmModelDisk.ps1 -DeleteVm` runs `az vm deallocate`, `az vm disk detach`, then (if `-DeleteVm` was passed) `az vm delete --yes`. The data disk remains in the workload RG, ready for the next `06-Deploy-LlmVm.ps1` invocation to re-attach.

**Alternatives considered:**

- *Stage to a Blob container, then download Blob → VM at boot* — was the previous design. Rejected because (a) the operator-staging step had to live somewhere (operator workstation, Cloud Shell, or temp VM — each with downsides), (b) added a storage account and Storage RBAC, (c) added a re-download on every VM rebuild even though the data disk was already going to persist, (d) the only thing Blob bought over the data disk alone was disaster recovery if the disk was lost — and the operator explicitly accepts re-pulling from HF in that case. Drop the entire Blob layer.
- *Pull from Hugging Face on first boot via cloud-init* — Couples model download to VM creation, which is the wrong shape: the VM-up phase needs to succeed for cert issuance regardless of whether HF is reachable, and we want the model load to be a separately retryable step. The current shape (cloud-init → cert → wait → util script → model → start) makes each phase independently observable and retryable.
- *Bake the model into a custom VM image* — Fastest boot, but introduces image-build pipeline (Packer or `az image create`) and image lifecycle. Defer.

**Rationale:** Single canonical store (the disk), no operator workstation involvement in the bytes, persistence across VM rebuilds, and a clear DR story (re-run the util script). Storage account complexity is dropped entirely.

### D5b. Persistent data disk lifecycle

**Chosen:** the data disk is a standalone Azure resource owned by the workload RG, never bundled into a VM-create call. Its lifecycle:

- **Create:** `05-Deploy-LlmDataDisk.ps1` runs `az disk create --size-gb 8 --sku StandardSSD_LRS …` only if `az disk show` reports the disk does not exist. Re-runs are a no-op. The script does not resize, retype, or re-tag an existing disk.
- **Attach:** `06-Deploy-LlmVm.ps1` resolves the disk ID and passes `--attach-data-disks <id>` (never `--data-disk-sizes-gb`, which would create a new disk bundled to the VM). It also pre-checks: if the disk is `Attached` to a different VM, fail with a clear error; if attached to this VM already, treat as success.
- **Detach:** `util/Detach-LlmModelDisk.ps1` runs `az vm disk detach`. Idempotent against an already-detached disk.
- **Delete:** never by `c-workload/` or `util/` scripts. The disk is only deleted by RG-level teardown of `rg-llm-workload-<env>-001` (e.g. `az group delete`, or a future `a-infrastructure/9x-Remove-WorkloadRg.ps1`) or by the operator manually via the portal/CLI when truly retiring the workload.

**Mount:** cloud-init mounts via `LABEL=llm-models` rather than by `/dev/sdc` or `/dev/disk/by-lun/0`, because:

- LUN paths can shift if other data disks are added in the future.
- A fixed device path would couple cloud-init to LUN ordering at attach time.
- The label is set by `mkfs` once and survives detach/reattach unchanged.
- The label `llm-models` is a constant — no template substitution needed.

The fstab entry is `LABEL=llm-models /opt/models ext4 defaults,nofail 0 2`. The `nofail` option ensures the VM boots even if the disk is missing (e.g. detached during a rebuild window), with `vllm.service`'s `ConditionPathExists` then keeping vLLM down until the disk is reattached and populated.

**Rationale:** decoupling the disk's lifecycle from the VM's is the entire point. Standalone resource + attach-by-ID + label-based mount makes detach/reattach trivial and unambiguous.

### D6. UAMI + Key Vault access policy (no Storage RBAC)

**Chosen:** `03-Deploy-LlmIdentity.ps1` creates a user-assigned managed identity `id-llm-vllm-<env>-001` in the workload RG. It grants exactly:

- `get, list` on **secrets** in the **shared Key Vault** via `az keyvault set-policy --object-id <uami-principalId>` (matches access-policy mode).

No Storage RBAC roles are granted; no storage account exists in this design.

`06-Deploy-LlmVm.ps1` binds the UAMI at VM-create time (`--assign-identity <uami-resourceId>`). Cloud-init's `runcmd` logs in once with the UAMI:

```sh
az login --identity --username "$UAMI_CLIENT_ID"
```

then performs the API-key fetch from Key Vault. The `--username` form is required because a VM can have multiple identities; we want the explicit one.

The UAMI's `clientId` is substituted into cloud-init via `#INIT_UAMI_CLIENT_ID#`; not a secret, just a GUID that identifies which identity to use.

**Alternatives considered:**

- *System-assigned managed identity* — Same race-condition objection as the strongSwan design (D4 of `configure-strongswan-vm/design.md`): SA-MI only materialises after `az vm create` returns, forcing a permission grant just before cloud-init's first `az login --identity`. Pre-creating a UAMI avoids this entirely.
- *RBAC on Key Vault* — The shared Key Vault is in access-policy mode (per `b-shared/02-Deploy-KeyVault.ps1`); switching it to RBAC mode would also require Owner permissions for the operator. Stay in access-policy mode for Key Vault.
- *Store the API key in cloud-init `--custom-data`* — Visible to every process on the VM via IMDS. Rejected.

**Rationale:** Mirrors the strongSwan pattern that already works in this repo, fits the operator's Contributor-only permissions, and keeps cloud-init linear. Dropping the storage account also drops the entire data-plane RBAC propagation risk class.

### D7. Subnet inside the existing workload VNet, dedicated NSG, three inbound allow rules

**Chosen:** A new subnet `snet-llm-vllm-<env>-<location>-001` is added inside the existing `vnet-llm-workload-<env>-<location>-001` (created by `a-infrastructure/02-Initialize-WorkloadRg.ps1`). The subnet is a `/64` IPv6 + `/27` IPv4 (matching the project's per-subnet sizing).

`<vv>` (VNet ID) is `02` (the workload VNet's ID, fixed by `a-infrastructure/02-Initialize-WorkloadRg.ps1` `DEPLOY_WORKLOAD_VNET_ID` default).
`<ss>` (subnet ID inside the workload VNet) is `01` for this subnet.

Subnet prefixes (using the project's per-subnet formula `fd<gg>:<gggg>:<gggggg>:<vv><ss>::/64` for IPv6 and `10.<gg>.<vv>.<ss*32>/27` for IPv4):

| Layer | Prefix |
|---|---|
| IPv6 | `fd<gg>:<gggg>:<gggggg>:0201::/64` |
| IPv4 | `10.<gg>.2.32/27` |

A new NSG `nsg-llm-vllm-<env>-001` is associated to the subnet with three inbound allow rules:

| Priority | Name | Direction | Protocol | Dest port | Source | Action |
|---|---|---|---|---|---|---|
| 1000 | `AllowSshInbound` | Inbound | TCP | 22 | `*` | Allow |
| 1010 | `AllowHttpInbound` | Inbound | TCP | 80 | `*` | Allow |
| 1020 | `AllowHttpsInbound` | Inbound | TCP | 443 | `*` | Allow |

Default deny-inbound from Azure's NSG default chain handles everything else. No outbound rules added (default allow-internet outbound is fine — it's needed for `apt`, `pip`, ACME, NVIDIA repos, and Hugging Face).

**Alternatives considered:**

- *Restrict source to operator's IP* — Rejected because Let's Encrypt's HTTP-01 challenge requires the validation server to be reachable from LE's validators (which come from many IPs and are not published as a stable list).
- *Restrict 22 to operator's IP* — Possible but fragile (home IPs change). Match the IoT-repo pattern (open 22, key-only auth).
- *Use `core-infrastructure`'s existing rules for the workload subnet* — Rejected: a workload-specific NSG keeps the LLM VM's posture independently revisable without affecting any future workloads in the same VNet.

**Rationale:** Matches `core-infrastructure`'s subnet/addressing scheme, keeps NSG scope small and revisable, and accepts the same SSH-open-to-internet posture used in the IoT reference.

### D8. Public IPs: dual-stack Standard SKU, static, with deterministic DNS labels

**Chosen:** `04-Deploy-LlmPublicIp.ps1` creates:

- `pip-llm-vllm-<env>-<location>-001` — IPv6, Standard, static, DNS label `llm-<orgid>-<env>` → `llm-<orgid>-<env>.<location>.cloudapp.azure.com`.
- `pipv4-llm-vllm-<env>-<location>-001` — IPv4, Standard, static, DNS label `llm-<orgid>-<env>-ipv4` → `llm-<orgid>-<env>-ipv4.<location>.cloudapp.azure.com`.

`<orgid>` = `0x` + first 4 hex of the subscription id, matching the project-wide pattern in `AGENTS.md` and `core-infrastructure`.

The IPv6 FQDN is the **primary** name and is what the Let's Encrypt cert is issued for. The IPv4 FQDN is included as an additional `subjectAltName` (`-d <ipv6-fqdn> -d <ipv4-fqdn>`) so OpenCode can connect over either.

**Alternatives considered:**

- *Single IP* — Azure VMs require an IPv4 (Azure platform constraint, matched in `azure-leshan`). Both is right.
- *Operator-supplied DNS* — Rejected: requires the operator to own a domain and create A/AAAA records, doubling the prerequisites for no real gain over `cloudapp.azure.com`.
- *Dynamic IP allocation* — Static is required so the DNS label doesn't drift across stop/start cycles. Standard SKU is required to allow a NIC to attach an IPv6 PIP on Azure.

**Rationale:** Matches the `azure-leshan` and `azure-mosquitto` patterns, free DNS, no external registrar dependency, and Let's Encrypt issues against `cloudapp.azure.com` with no special handling.

### D9. VM SKU: `Standard_NC4as_T4_v3` with NVIDIA driver VM extension

**Chosen:** Single VM, `Standard_NC4as_T4_v3` (4 vCPU, 28 GB RAM, 1× T4 16 GB), Ubuntu 22.04 LTS, NVIDIA GPU Driver Linux extension applied at create time.

VM disk: default OS disk only (~30 GB) plus the attached persistent data disk for models (`/opt/models`).

Auto-shutdown configured via `az vm auto-shutdown` at a fixed UTC time (default `0900` UTC = 19:00 in Brisbane, matching `azure-leshan`).

**Alternatives considered:**

- *`Standard_NC8as_T4_v3` (1× T4, 8 vCPU)* — More CPU; not bottlenecked by CPU at this workload. Costs more for nothing.
- *`Standard_NC6s_v3` (1× V100 16 GB)* — Older, no longer the cheapest GPU per region; T4 is the modern dev-tier choice.
- *`Standard_NV6ads_A10_v5` (1/6× A10)* — Partitioned A10. Cheaper, but A10 is overkill for 7B; T4 has been validated for AWQ-INT4 7B at 32K context.
- *CPU-only VM with llama.cpp* — Rejected in earlier planning; OpenCode agent loops are too chatty for CPU inference.
- *Spot VMs* — Not supported on most NC SKUs; would also break `Start-/Stop-LlmVm.ps1` semantics.

**Rationale:** Smallest currently-available T4 SKU on Azure, matches the model size, has documented quota availability in mainstream regions, supports the NVIDIA driver extension. The trade-off is GPU quota (often zero on a fresh subscription); the deploy script checks quota up-front and emits a clear error if zero.

### D10. AWQ-INT4 quantisation, served by vLLM

**Chosen:** `Qwen/Qwen2.5-Coder-7B-Instruct-AWQ` (Apache-2.0, ~5.5 GB), passed to vLLM via `--model /opt/models/qwen2.5-coder-7b-awq` and `--served-model-name qwen2.5-coder-7b`.

vLLM detects AWQ from the model's `config.json` and selects the AWQ kernel automatically; no explicit `--quantization` flag needed in current vLLM versions.

Tool calling: `--tool-call-parser hermes --enable-auto-tool-choice`. Qwen2.5-Coder uses Hermes-style tool tokens.

Context length: `--max-model-len 32768`. Qwen2.5-Coder-7B's training context is 32K; vLLM defaults can reserve more KV cache than fits on a T4 unless capped.

**Alternatives considered:**

- *GPTQ-INT4* — Similar quality and VRAM, slightly less common in vLLM's published benchmarks. AWQ is the safer default for this size.
- *FP16 unquantised* — ~14 GB VRAM; just barely fits T4 with very reduced context. Risky on this SKU.
- *GGUF Q4_K_M* — vLLM's GGUF support is recent and less battle-tested; the Ollama/llama.cpp ecosystem is the natural home for GGUF.
- *Smaller Qwen variant (3B / 1.5B / 0.6B)* — Tool-calling reliability degrades sharply. 7B is the smallest size that works well as an OpenCode agent.

**Rationale:** Best quality at 4-bit, native vLLM support, proven on T4, comfortable with 32K context.

### D11. Script inventory — flat layout, sequential numbering, no removal scripts

**Chosen:** Scripts live directly in `c-workload/` with numeric prefixes `01..07` for deploy, no-prefix for utilities. Cross-workload helpers go in `util/`.

| Path | Role |
|---|---|
| `c-workload/01-Deploy-LlmSubnet.ps1` | Subnet + NSG inside existing workload VNet |
| `c-workload/02-Deploy-LlmKeyVaultSecret.ps1` | Generates and stores `vllm-api-key` in shared Key Vault |
| `c-workload/03-Deploy-LlmIdentity.ps1` | UAMI + KV access policy (`get,list` on secrets) |
| `c-workload/04-Deploy-LlmPublicIp.ps1` | Static dual-stack PIPs with `cloudapp.azure.com` DNS labels |
| `c-workload/05-Deploy-LlmDataDisk.ps1` | Standalone 8 GiB Standard SSD for `/opt/models` |
| `c-workload/06-Deploy-LlmVm.ps1` | NIC, VM, NVIDIA extension, auto-shutdown, attach data disk, custom-data cloud-init |
| `c-workload/07-Test-LlmEndpoint.ps1` | `/v1/models` + tool-call smoke test |
| `c-workload/Stop-LlmVm.ps1`, `Start-LlmVm.ps1`, `Rotate-LlmApiKey.ps1` | Operational utilities |
| `c-workload/data/vllm-cloud-init.txt` | Cloud-init template |
| `util/Download-LlmModelToDisk.ps1` | HF → `/opt/models` on the VM via `run-command invoke` |
| `util/Detach-LlmModelDisk.ps1` | Deallocate VM, detach data disk, optionally `az vm delete` |

Substituted cloud-init lands at `c-workload/temp/vllm-cloud-init.txt~` (gitignored — `**/temp/` rule in `.gitignore`). No `9x-Remove-*.ps1` script exists in `c-workload/`; RG-level teardown of `rg-llm-workload-<env>-001` is owned by `a-infrastructure/` (today via `az group delete`, in future via a dedicated removal script).

**Alternatives considered:**

- *Nested folder `c-workload/azure-vllm/`* — Mirrors the IoT repo's `azure-leshan/`/`azure-mosquitto/` convention. Considered and rejected: the project has only one workload today; flat-with-numeric-prefixes matches `a-infrastructure/` and `b-shared/`. Re-folder if a second workload is added.
- *Combine scripts (e.g. fold subnet + identity into one Deploy-Llm.ps1)* — Rejected: each step has a different lifecycle and a different Azure scope. Splitting also means rotating the API key doesn't redeploy the VM.
- *Put `Download-LlmModelToDisk.ps1` and `Detach-LlmModelDisk.ps1` inside `c-workload/`* — Rejected: these are operator-triggered, post-deploy, post-VM operations conceptually parallel to the existing one-shot helpers in `util/`. Keeping them out of the numbered chain makes the deploy sequence cleaner.

**Rationale:** Matches the established style of the repo (`a-infrastructure/01-…`, `b-shared/02-…`), makes the dependency order self-documenting, and lets each step be re-run independently.

### D12. cloud-init template substitution

The deploy script substitutes these tokens into a copy of `c-workload/data/vllm-cloud-init.txt` written to `c-workload/temp/vllm-cloud-init.txt~`:

| Token | Substituted value |
|---|---|
| `#INIT_HOST_NAME#` | Primary FQDN (IPv6 `cloudapp.azure.com` label) |
| `#INIT_HOST_NAME_IPV4#` | IPv4 FQDN, used as additional ACME `-d` flag |
| `#INIT_KEY_VAULT_NAME#` | Name of the shared Key Vault |
| `#INIT_API_KEY_SECRET_NAME#` | `vllm-api-key` |
| `#INIT_UAMI_CLIENT_ID#` | `clientId` of the UAMI from script 03 |
| `#INIT_CERT_EMAIL#` | Operator-supplied `-AcmeEmail` (or `DEPLOY_ACME_EMAIL`) |
| `#INIT_ACME_STAGING_FLAG#` | Empty by default; `--test-cert` when `-AcmeStaging` is passed |
| `#INIT_VLLM_VERSION#` | Pinned vLLM version (e.g. `0.6.4`) |
| `#INIT_SERVED_MODEL_NAME#` | `qwen2.5-coder-7b` |
| `#INIT_MODEL_DIR_NAME#` | `qwen2.5-coder-7b-awq` (subdir under the mount point) |
| `#INIT_MODEL_MOUNT_POINT#` | `/opt/models` |

No secrets are substituted into cloud-init: the API key is fetched at boot from Key Vault using the UAMI; the model bytes are fetched later via the operator-triggered util script.

### D13. systemd unit for vLLM, with `ConditionPathExists` guard

**Chosen:** `/etc/systemd/system/vllm.service`:

```ini
[Unit]
Description=vLLM OpenAI-compatible server
After=network-online.target opt-models.mount
Wants=network-online.target
ConditionPathExists=/opt/models/qwen2.5-coder-7b-awq/config.json

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

Cloud-init `enable`s the unit but does not `start` it. The `ConditionPathExists` line keeps the unit inactive (silently, no error) until `util/Download-LlmModelToDisk.ps1` populates the directory. After that script runs `systemctl start vllm`, the unit comes up and stays up across reboots.

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

**Rationale:** Single source of truth for the key (Key Vault), in-process env-var consumption matches vLLM's documented `--api-key ${VAR}` pattern, rotation needs no VM rebuild, and the `ConditionPathExists` guard cleanly decouples "VM up + TLS healthy" from "model ready" — useful for staging and for surviving disk-detached states.

### D14. Smoke test contract (`07-Test-LlmEndpoint.ps1`)

The test fetches the API key from Key Vault and the FQDN from the public IP, then makes two HTTPS calls:

1. `GET https://<fqdn>/v1/models` with `Authorization: Bearer <key>` — asserts 200 and that the response `data[].id` array contains `qwen2.5-coder-7b`.
2. `POST https://<fqdn>/v1/chat/completions` with a single tool definition (`get_weather(location: string)`) and a user message `"what's the weather in London?"` — asserts 200 and that `choices[0].message.tool_calls` is a non-empty array whose first entry has `function.name == "get_weather"`.

Both calls go via `Invoke-RestMethod` with default certificate validation (so a real Let's Encrypt cert is required to pass without flags; with `-AcmeStaging` the script emits a warning and uses `-SkipCertificateCheck`).

Documented prerequisite: `util/Download-LlmModelToDisk.ps1` has been run at least once. If `vllm.service` is inactive (model not yet loaded), the GET to `/v1/models` will fail at the TCP level and the script exits non-zero with a hint pointing at the util script.

The script exits 0 on both passes, non-zero with diagnostic output on any failure.

**Rationale:** Validates the only two capabilities that matter for OpenCode: that the OpenAI-compatible endpoint serves the model under the expected name, and that tool-calling round-trips correctly. Anything else is implementation detail.

### D15. Naming and tagging

Naming pattern (matches `core-infrastructure`):

| Resource | Pattern | Example |
|---|---|---|
| Subnet | `snet-llm-vllm-<env>-<location>-001` | `snet-llm-vllm-dev-australiaeast-001` |
| NSG | `nsg-llm-vllm-<env>-001` | `nsg-llm-vllm-dev-001` |
| Key Vault secret | `vllm-api-key` | `vllm-api-key` |
| User-assigned identity | `id-llm-vllm-<env>-001` | `id-llm-vllm-dev-001` |
| Public IPv6 | `pip-llm-vllm-<env>-<loc>-001` | `pip-llm-vllm-dev-australiaeast-001` |
| Public IPv4 | `pipv4-llm-vllm-<env>-<loc>-001` | `pipv4-llm-vllm-dev-australiaeast-001` |
| IPv6 DNS label | `llm-<orgid>-<env>` | `llm-0xacc5-dev` |
| IPv4 DNS label | `llm-<orgid>-<env>-ipv4` | `llm-0xacc5-dev-ipv4` |
| Data disk | `disk-llm-vllm-models-<env>-001` | `disk-llm-vllm-models-dev-001` |
| Disk filesystem label | `llm-models` | `llm-models` |
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
- **[vLLM version drift]** → vLLM's CLI flags change between minor versions (notably `--tool-call-parser` and quantisation flags). Mitigation: pin to a specific version (`-VllmVersion 0.6.4` parameter, default in script 06; pinned in cloud-init's `pip install vllm==<version>`). Updating is a deliberate operator action.
- **[Hugging Face availability is the only DR path for the model]** → If the data disk is lost (accidental delete, region failure, accidental `--data-disk-sizes-gb` recreating it), the operator must re-pull the model from `huggingface.co`, which depends on HF being reachable and the `Qwen/Qwen2.5-Coder-7B-Instruct-AWQ` repo existing. Explicitly accepted; documented in README. README also documents how to override the source repo with `-ModelRepoId` on `util/Download-LlmModelToDisk.ps1`.
- **[Let's Encrypt rate limits during dev iteration]** → 5 duplicate certs per `cloudapp.azure.com` subdomain per week. Mitigation: `-AcmeStaging` switch on `06-Deploy-LlmVm.ps1` (default off, prod cert by default).
- **[vLLM cert reload requires restart, not reload]** → ~30-60s downtime once every ~60 days during cert renewal. Acceptable for a single-user dev endpoint.
- **[Public TCP 22 from internet]** → Accepted; matches the IoT-repo reference. Key-only auth (`--generate-ssh-keys`).
- **[Single shared bearer token]** → A token leak grants full inference access until rotated. Mitigations: rotation via `Rotate-LlmApiKey.ps1` (no rebuild), Key Vault as the source of truth, future LiteLLM proxy will replace this with per-user keys.
- **[Port 80 used briefly during cert issuance/renewal]** → vLLM never binds 80, so no conflict; certbot standalone takes 80 transiently. Documented; NSG must allow 80 inbound.
- **[Cloud-init failures are silent until polled]** → `06-Deploy-LlmVm.ps1` runs `az vm run-command invoke -- "cloud-init status --wait"` after `az vm create` returns and fails the deployment if the final status is not `done`. Logs from `/var/log/cloud-init-output.log` are streamed to the operator on failure.
- **[Data-disk label collision]** → If the operator manually attaches a second disk labelled `llm-models`, fstab's first match wins; results undefined. Mitigation: README documents that no other disk in the workload RG should carry that label.
- **[Detach-then-rebuild requires the operator to follow the documented order]** → Calling `az vm delete` on a VM with the data disk still attached will *not* delete the disk by default (Azure preserves data disks unless `--force-deletion` is passed), but a careless `az vm create … --data-disk-sizes-gb 8` would create a *new* disk and ignore the existing one. Mitigation: `06-Deploy-LlmVm.ps1` always uses `--attach-data-disks`, never `--data-disk-sizes-gb`, and pre-checks that the named disk exists. README documents the rebuild flow explicitly.
- **[`Rotate-LlmApiKey.ps1` while vLLM is mid-request]** → Existing connections may receive a 401 on subsequent calls until the client re-reads the key. Acceptable for a dev endpoint.
- **[Hugging Face download time (~5 min on Azure backbone)]** → Long enough that `az vm run-command invoke`'s ~1h limit is fine, but operators need to expect a wait. Verbose output streams the `huggingface-cli` progress.

## Migration Plan

This is the first workload in `c-workload/`; there is no prior version to migrate from.

1. Merge proposal + design + specs + tasks.
2. Operator confirms T4 quota in their region (one-time, may take days for a new subscription).
3. Operator runs in order:
   - `a-infrastructure/01..03` (RGs + VNets + peering)
   - `b-shared/01-02` (Azure Monitor + Key Vault)
   - `c-workload/01-Deploy-LlmSubnet.ps1`
   - `c-workload/02-Deploy-LlmKeyVaultSecret.ps1`
   - `c-workload/03-Deploy-LlmIdentity.ps1`
   - `c-workload/04-Deploy-LlmPublicIp.ps1`
   - `c-workload/05-Deploy-LlmDataDisk.ps1`
   - `c-workload/06-Deploy-LlmVm.ps1` (the long one — VM create + cloud-init ~10–15 min, ends with cert issued and `vllm.service` enabled but inactive)
   - `util/Download-LlmModelToDisk.ps1` (HF → data disk via `run-command invoke`, ~5 min, ends with `vllm.service` started)
   - `c-workload/07-Test-LlmEndpoint.ps1` (the validation step)
4. Operator copies the printed FQDN + retrieves the API key from Key Vault, configures OpenCode per `docs/OpenCode-vllm-config.md`.
5. Daily ops:
   - `Stop-LlmVm.ps1` at end of day, `Start-LlmVm.ps1` next morning (or rely on auto-shutdown + manual start).
6. VM-rebuild flow (preserving the model on the data disk):
   - `util/Detach-LlmModelDisk.ps1 -DeleteVm` → deallocate, detach disk, delete VM + OS disk + NIC.
   - `c-workload/06-Deploy-LlmVm.ps1` again → re-attaches the same disk; cloud-init re-issues cert; `ConditionPathExists` is already satisfied so `vllm.service` starts automatically.
7. API-key rotation: `Rotate-LlmApiKey.ps1`. No VM rebuild.
8. Future replacement (out of scope): introduce LiteLLM as a separate VM or container in front; switch the public DNS label to point at LiteLLM; vLLM moves to a private endpoint inside the VNet.

## Open Questions

- **Should `vllm-api-key` be rotated on a schedule rather than on-demand?** Out of scope here. A future change could introduce a Key Vault rotation policy + deploy hook.
- **Should we surface the vLLM Prometheus metrics endpoint?** vLLM exposes `/metrics`; we currently leave it on the same `:443` listener (so it's behind the bearer token via vLLM's `--api-key`). A future Azure Monitor / Managed Grafana integration is possible.
- **Should auto-shutdown be configurable per-environment via parameter or always 19:00 local?** Match `azure-leshan` for consistency: `-ShutdownUtc` parameter with `0900` UTC default; operator overrides for non-AEST timezones.
- **Should `setcap` be run on a stable Python symlink rather than the venv's `python3*`?** The venv pins to a specific Python minor version (3.10, 3.11, …). If Ubuntu's package manager upgrades the underlying interpreter, the venv keeps a copy; capability survives. Confirmed safe; documented in the script comment.
- **Should we ship a second model concurrently?** No — vLLM is one model per process. Multi-model is a LiteLLM-era concern.
- **Should the data disk be encrypted with a customer-managed key?** Out of scope. Default platform-managed encryption applies (Azure Disk Encryption with platform key).
