# c-workload

Workload-specific deployments. The first (and currently only) workload is a
single-VM **vLLM** server running **Qwen2.5-Coder-7B-Instruct (AWQ-INT4)** on a
T4 GPU, exposed publicly over HTTPS with a Let's Encrypt certificate and a
shared bearer-token API key.

## Prerequisites

- `a-infrastructure/01-Initialize-CoreRg.ps1` and `02-Initialize-WorkloadRg.ps1`
  have run for the target environment. The workload RG
  `rg-llm-workload-<env>-001` and its VNet
  `vnet-llm-workload-<env>-<region>-001` must exist.
- `b-shared/01-Deploy-CoreVnet.ps1` and `02-Deploy-KeyVault.ps1` have run.
  The shared Key Vault `kv-llm-shared-<orgid>-<env>` must exist.
- A Microsoft Azure subscription with **GPU quota for `standardNCASv3Family`**
  in the target region (≥ 4 vCPUs for `Standard_NC4as_T4_v3`). T4 quota is
  off by default on new subscriptions; request a quota increase via the
  portal: <https://learn.microsoft.com/azure/quotas/per-vm-quota-requests>.
- The operator workstation has Azure CLI signed in (`az login`) with
  Contributor on the workload RG and Key Vault Administrator (or equivalent
  access-policy permissions) on the shared Key Vault.
- A real email address for the Let's Encrypt registration.

## Deploy order

Run in numeric order; each script is idempotent and can be re-run safely.

| # | Script                            | What it creates                                                              |
|---|-----------------------------------|------------------------------------------------------------------------------|
| 1 | `01-Deploy-LlmSubnet.ps1`         | LLM subnet (`snet-llm-vllm-…`) + NSG with rules for 22/80/443.               |
| 2 | `02-Deploy-LlmKeyVaultSecret.ps1` | `vllm-api-key` secret (256-bit URL-safe-base64) in the shared Key Vault.     |
| 3 | `03-Deploy-LlmIdentity.ps1`       | UAMI `id-llm-vllm-…` + Key Vault `get,list` access policy.                   |
| 4 | `04-Deploy-LlmPublicIp.ps1`       | IPv6 PIP (cert primary) + IPv4 PIP (cert SAN), both with `cloudapp` DNS.     |
| 5 | `05-Deploy-LlmDataDisk.ps1`       | Standalone 8 GiB Managed Disk for model weights. Lifecycle independent of VM.|
| 6 | `06-Deploy-LlmVm.ps1`             | NIC, VM (`Standard_NC4as_T4_v3`), NVIDIA driver, cloud-init, auto-shutdown.  |

After `06` finishes, **`vllm.service` is `enabled` but `inactive`** because no
model is on disk yet. The next two steps are the model load and the smoke test:

| # | Script                                     | What it does                                                  |
|---|--------------------------------------------|---------------------------------------------------------------|
| - | `util/Download-LlmModelToDisk.ps1`         | Pulls ~5.5 GiB from HF onto the data disk; starts vllm.       |
| 7 | `07-Test-LlmEndpoint.ps1`                  | Smoke-tests `/v1/models` + tool-calling against the live cert.|

`Download-LlmModelToDisk.ps1` lives in `util/` because its lifecycle is
operator-driven, not part of "stand up the infrastructure". It is also the
recovery path if the data disk is ever lost.

## Operational scripts

| Script                       | Purpose                                                            |
|------------------------------|--------------------------------------------------------------------|
| `Stop-LlmVm.ps1`             | Deallocate the VM (stop compute billing). Idempotent.              |
| `Start-LlmVm.ps1`            | Start a deallocated VM. Idempotent.                                |
| `Rotate-LlmApiKey.ps1`       | New random key in Key Vault → rewrite `/etc/vllm/vllm.env` → restart. No VM rebuild. |
| `util/Detach-LlmModelDisk.ps1`| Deallocate + detach data disk. With `-DeleteVm`, also delete the VM. |

## Rebuild the VM, keep the model

The persistent data disk is the entire reason the deploy is shaped this way:
**a VM rebuild does not require re-downloading the model from Hugging Face.**

```pwsh
./util/Detach-LlmModelDisk.ps1 -DeleteVm
./c-workload/06-Deploy-LlmVm.ps1
```

What happens:

1. `Detach-LlmModelDisk.ps1 -DeleteVm` deallocates the VM, detaches the data
   disk, and deletes the VM (with its OS disk and NIC). The data disk
   `disk-llm-vllm-models-<env>-001` remains in the workload RG, `Unattached`.
2. `06-Deploy-LlmVm.ps1` re-creates the NIC and VM, and re-attaches the same
   data disk via `--attach-data-disks <disk-id>`. Cloud-init's `mkfs` step
   skips because `blkid` reports the existing ext4 filesystem; the
   `LABEL=llm-models` fstab entry mounts it; `vllm.service` starts
   automatically because `ConditionPathExists` is satisfied immediately
   after the cert step finishes.
3. `07-Test-LlmEndpoint.ps1` passes again. **No HF download.**

There is **no `9x-Remove-*.ps1` script in `c-workload/`**. Removal of the
workload RG itself is a `a-infrastructure/`-level concern (today: `az group
delete` directly; in future: a dedicated removal script).

## Hostname pattern

| FQDN              | Pattern                                                          |
|-------------------|------------------------------------------------------------------|
| IPv6 (primary)    | `llm-<orgid>-<env>.<region>.cloudapp.azure.com`                  |
| IPv4 (fallback)   | `llm-<orgid>-<env>-ipv4.<region>.cloudapp.azure.com`             |

OpenCode connects to the IPv6 FQDN. `<orgid>` is `0x` + the first four hex
chars of the subscription id, ensuring globally-unique DNS labels per
subscription.

## OpenCode wiring

After 13 passes, see [`docs/OpenCode-vllm-config.md`](../docs/OpenCode-vllm-config.md)
for a copy-pasteable `~/.config/opencode/opencode.json` snippet.

## Cost notes

- **Compute (when running):** `Standard_NC4as_T4_v3` is the cheapest T4 SKU
  (~AUD 0.50/hour pay-as-you-go in `australiaeast`, varies by region). The
  default auto-shutdown at 0900 UTC (≈ 19:00 Brisbane) caps daily runaway.
- **Compute (when deallocated):** $0.
- **Storage:** OS disk (~30 GiB Premium SSD by default) + the 8 GiB
  StandardSSD data disk. Single-digit AUD per month combined.
- **Network:** Standard SKU public IPs; both v6 and v4 carry small per-hour
  charges (cents per day each). Bandwidth is metered egress only.

## Troubleshooting

- **`06-Deploy-LlmVm.ps1` fails on quota.** Request a `standardNCASv3Family`
  quota increase. Default new subscriptions get 0.
- **cloud-init never reaches `done`.** The script dumps the last 200 lines of
  `/var/log/cloud-init-output.log` automatically on failure. Common causes:
  certbot rate-limited (try `-AcmeStaging` first when iterating), HF/PyPI
  egress blocked, NSG misconfigured.
- **`vllm.service` is `inactive` after `06` finishes.** Expected. Run
  `util/Download-LlmModelToDisk.ps1`. The unit's `ConditionPathExists` keeps
  it inactive until the model directory contains `config.json`.
- **`vllm.service` is `inactive` after the model download.** SSH into the VM
  and run `journalctl -u vllm -n 200`. Common cause: AWQ requires the
  `--quantization awq_marlin` autodetect to land on a compatible kernel; if
  vLLM is too old or too new for the model files, pin a known-good
  `-VllmVersion`.
- **Cert renewal is failing.** The certbot.timer systemd unit runs twice
  daily. Check `journalctl -u certbot.timer` and `journalctl -u certbot`.
  The deploy hook at `/etc/letsencrypt/renewal-hooks/deploy/10-vllm-restart.sh`
  is what copies cert material into `/etc/vllm/certs` and restarts vllm.
- **Smoke test fails with TCP-level error.** `vllm.service` is probably not
  active. Run the model-download util script.

## Disaster recovery

The data disk is the only canonical store for the model files. If the disk
is lost (deleted, or a region-wide failure), recovery is **`util/Download-LlmModelToDisk.ps1`**
against a fresh VM. This explicitly accepts a Hugging-Face dependency for DR:
no Azure-side backup of the weights is maintained. ~5 minutes of HF download
is faster than any plausible backup pipeline would be to set up and audit.
