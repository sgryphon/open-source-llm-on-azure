## ADDED Requirements

### Requirement: Scripts SHALL live in `c-workload/` and `util/` with the documented layout

All deploy and operational scripts for this capability SHALL live directly
in the top-level `c-workload/` folder, flat (no nested per-workload
subfolder). Deploy scripts SHALL be numbered `01`–`07` in dependency order.
Operational utility scripts (start/stop/rotate) SHALL NOT carry numeric
prefixes. The cloud-init template SHALL live under `c-workload/data/`.

This capability SHALL NOT introduce any `9x-Remove-*.ps1` script in
`c-workload/`. Reverse-direction operations on individual resources are
limited to scripts in `util/`, of which exactly two SHALL be created by
this capability: `util/Download-LlmModelToDisk.ps1` (model load) and
`util/Detach-LlmModelDisk.ps1` (detach the persistent data disk before VM
deletion).

#### Scenario: Directory listing shows scripts in execution order

- **WHEN** a developer runs `ls c-workload/`
- **THEN** the listing contains, in order, `01-Deploy-LlmSubnet.ps1`,
  `02-Deploy-LlmKeyVaultSecret.ps1`, `03-Deploy-LlmIdentity.ps1`,
  `04-Deploy-LlmPublicIp.ps1`, `05-Deploy-LlmDataDisk.ps1`,
  `06-Deploy-LlmVm.ps1`, `07-Test-LlmEndpoint.ps1`, the utility scripts
  `Start-LlmVm.ps1`, `Stop-LlmVm.ps1`, `Rotate-LlmApiKey.ps1`,
  a `data/` directory containing `vllm-cloud-init.txt`, and a `README.md`.

#### Scenario: No removal script exists in c-workload

- **WHEN** a developer lists `c-workload/`
- **THEN** no file matching the pattern `9?-Remove-*.ps1` is present.

#### Scenario: Util folder contains exactly the two cross-cutting helpers

- **WHEN** a developer runs `ls util/Download-LlmModelToDisk.ps1
  util/Detach-LlmModelDisk.ps1`
- **THEN** both files exist and are executable PowerShell scripts owned by
  this capability.

### Requirement: Scripts SHALL be PowerShell invoking Azure CLI

Every script SHALL start with `#!/usr/bin/env pwsh`, use `[CmdletBinding()]`,
typed `param()` blocks, `$ErrorActionPreference = 'Stop'`, and use `az` CLI
commands for all Azure operations (no `Az` PowerShell module, no Bicep, no
Terraform). Every script SHALL include PowerShell comment-based help with
`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`, and at least one `.EXAMPLE` section.
Each significant step SHALL emit `Write-Verbose` output so that setting
`$VerbosePreference = 'Continue'` produces a readable trace.

#### Scenario: Script help is discoverable

- **WHEN** a developer runs `Get-Help ./c-workload/06-Deploy-LlmVm.ps1 -Full`
- **THEN** synopsis, description, notes, parameter descriptions, and at
  least one example are displayed.

#### Scenario: Verbose output traces major steps

- **GIVEN** `$VerbosePreference = 'Continue'`
- **WHEN** any deploy script is executed
- **THEN** a `VERBOSE:` line is emitted for each Azure resource create or
  update operation the script performs.

### Requirement: Scripts SHALL accept standard parameters with environment-variable fallbacks

Every deploy script SHALL accept at minimum the following parameters, each
with an environment-variable fallback and the specified default:

| Parameter      | Env var fallback     | Default                                              |
|----------------|----------------------|------------------------------------------------------|
| `-Environment` | `DEPLOY_ENVIRONMENT` | `Dev`                                                |
| `-Location`    | `DEPLOY_LOCATION`    | `australiaeast`                                      |
| `-OrgId`       | `DEPLOY_ORG_ID`      | `0x` + first 4 hex chars of the subscription id      |

Scripts that need an ACME email SHALL additionally accept `-AcmeEmail` with
fallback `DEPLOY_ACME_EMAIL` (no default; required for `06-Deploy-LlmVm.ps1`).
Scripts that need to opt into Let's Encrypt staging SHALL accept a switch
`-AcmeStaging` (off by default; production cert is the default).

#### Scenario: Default OrgId is derived from the current subscription

- **GIVEN** `-OrgId` is not passed and `$env:DEPLOY_ORG_ID` is not set
- **WHEN** any deploy script starts
- **THEN** it computes the OrgId as `0x` followed by the first four hex
  characters of `az account show --query id --output tsv`.

#### Scenario: Production ACME is the default

- **GIVEN** `-AcmeStaging` is not passed
- **WHEN** `06-Deploy-LlmVm.ps1` runs
- **THEN** the cloud-init `#INIT_ACME_STAGING_FLAG#` token is substituted
  with the empty string and the resulting `certbot certonly` command
  targets the Let's Encrypt production environment.

### Requirement: Resource names SHALL follow the patterns documented in the design

Resources created by this capability SHALL be named according to the table
below, with `<env>` the lowercased value of `-Environment`, `<loc>` the
lowercased value of `-Location` (no dashes), and `<orgid>` the value of
`-OrgId`:

| Resource              | Pattern                                  |
|-----------------------|------------------------------------------|
| Subnet                | `snet-llm-vllm-<env>-<loc>-001`          |
| NSG                   | `nsg-llm-vllm-<env>-001`                 |
| Key Vault secret      | `vllm-api-key`                           |
| User-assigned identity| `id-llm-vllm-<env>-001`                  |
| Public IPv6           | `pip-llm-vllm-<env>-<loc>-001`           |
| Public IPv4           | `pipv4-llm-vllm-<env>-<loc>-001`         |
| IPv6 DNS label        | `llm-<orgid>-<env>`                      |
| IPv4 DNS label        | `llm-<orgid>-<env>-ipv4`                 |
| Data disk             | `disk-llm-vllm-models-<env>-001`         |
| Disk filesystem label | `llm-models`                             |
| NIC                   | `nic-01-vmllmvllm001-<env>-001`          |
| VM                    | `vmllmvllm001`                           |
| OS disk               | `osdiskvmllmvllm001`                     |

#### Scenario: Data disk name in Dev

- **WHEN** `05-Deploy-LlmDataDisk.ps1` runs with `-Environment Dev`
- **THEN** the Managed Disk created is named `disk-llm-vllm-models-dev-001`.

#### Scenario: IPv6 FQDN is the primary cert subject

- **WHEN** `04-Deploy-LlmPublicIp.ps1` runs with `-Environment Dev`,
  `-Location australiaeast`, `-OrgId 0xacc5`
- **THEN** the IPv6 PIP has DNS label `llm-0xacc5-dev` resolving to
  `llm-0xacc5-dev.australiaeast.cloudapp.azure.com`, and the IPv4 PIP has
  DNS label `llm-0xacc5-dev-ipv4` resolving to
  `llm-0xacc5-dev-ipv4.australiaeast.cloudapp.azure.com`.

### Requirement: Subnet SHALL be added inside the existing workload VNet

`01-Deploy-LlmSubnet.ps1` SHALL add one subnet inside the existing
`vnet-llm-workload-<env>-<loc>-001` VNet (created by
`a-infrastructure/03-deploy-workload-rg-vnet.ps1`). The subnet SHALL be
dual-stack with an IPv6 `/64` and an IPv4 `/27`, derived deterministically
using the workload-VNet ID `0300` and subnet ID `01`:

| Layer | Prefix                                  |
|-------|-----------------------------------------|
| IPv6  | `fd<gg>:<gggg>:<gggggg>:0301::/64`      |
| IPv4  | `10.<gg>.3.32/27`                       |

The script SHALL NOT modify the workload VNet's address space, peerings, or
any subnet other than the one it creates.

#### Scenario: Subnet prefixes are deterministic given UlaGlobalId

- **GIVEN** `UlaGlobalId` resolves to `abcdef0123`
- **WHEN** `01-Deploy-LlmSubnet.ps1` runs
- **THEN** the subnet has IPv6 prefix `fdab:cdef:0123:0301::/64` and IPv4
  prefix `10.171.3.32/27` (0xab = 171).

### Requirement: NSG SHALL allow only inbound 22, 80, and 443

`01-Deploy-LlmSubnet.ps1` SHALL create an NSG `nsg-llm-vllm-<env>-001`,
associate it with the new subnet, and configure exactly three inbound allow
rules:

| Priority | Name               | Protocol | Dest port | Source |
|----------|--------------------|----------|-----------|--------|
| 1000     | `AllowSshInbound`  | TCP      | 22        | `*`    |
| 1010     | `AllowHttpInbound` | TCP      | 80        | `*`    |
| 1020     | `AllowHttpsInbound`| TCP      | 443       | `*`    |

No additional inbound allow rules SHALL be created. No outbound rules SHALL
be created (Azure's default outbound allow is sufficient for `apt`, `pip`,
ACME, NVIDIA repositories, and Hugging Face).

#### Scenario: Only the three documented inbound rules are present

- **WHEN** `01-Deploy-LlmSubnet.ps1` completes successfully
- **THEN** `az network nsg rule list` for `nsg-llm-vllm-<env>-001` returns
  exactly three custom inbound rules with the names, ports, and priorities
  above, and no other custom rules.

### Requirement: API key SHALL be a 256-bit random secret in the shared Key Vault

`02-Deploy-LlmKeyVaultSecret.ps1` SHALL generate a 256-bit cryptographically
random value, encode it as URL-safe base64 (no padding), and store it in
the shared Key Vault (created by `b-shared/02-Deploy-KeyVault.ps1`) under
the secret name `vllm-api-key`. The Key Vault SHALL remain in access-policy
mode; the script SHALL NOT switch the vault to RBAC mode.

The script SHALL accept a `-Rotate` switch. Without `-Rotate`, an existing
`vllm-api-key` secret SHALL be left untouched. With `-Rotate`, the script
SHALL set a new secret value (creating a new Key Vault secret version).

#### Scenario: Existing secret is preserved without -Rotate

- **GIVEN** `vllm-api-key` already exists in the shared Key Vault
- **WHEN** `02-Deploy-LlmKeyVaultSecret.ps1` runs without `-Rotate`
- **THEN** the script exits 0 and no new secret version is created.

#### Scenario: -Rotate creates a new version

- **GIVEN** `vllm-api-key` already exists with version V1
- **WHEN** `02-Deploy-LlmKeyVaultSecret.ps1` runs with `-Rotate`
- **THEN** a new version V2 of `vllm-api-key` exists with a freshly
  generated 256-bit value.

### Requirement: UAMI SHALL hold only Key Vault secrets get/list and no Storage permissions

`03-Deploy-LlmIdentity.ps1` SHALL create a user-assigned managed identity
named `id-llm-vllm-<env>-001` in the workload resource group and grant it
exactly one permission set:

- `get` and `list` on **secrets** in the shared Key Vault, via
  `az keyvault set-policy` (access-policy mode).

The script SHALL NOT grant any Azure RBAC role assignments (no
`Storage Blob Data Reader`, no `Storage Blob Data Contributor`, no
`Reader`, no `Contributor`). The script SHALL NOT grant Key Vault access
policy permissions on keys or certificates.

#### Scenario: UAMI has the documented permissions and no others

- **WHEN** `03-Deploy-LlmIdentity.ps1` completes successfully
- **THEN** the UAMI's Key Vault access policy lists exactly `get,list` on
  secrets (and nothing on keys or certificates), and `az role assignment
  list --assignee <uami-principalId> --all` returns no role assignments.

### Requirement: Public IPs SHALL be dual-stack, Standard SKU, static, with cloudapp.azure.com DNS labels

`04-Deploy-LlmPublicIp.ps1` SHALL create exactly two public IP addresses,
one IPv6 and one IPv4, both Standard SKU and statically allocated, with
the DNS labels documented in the naming requirement above. No other DNS
provider SHALL be involved; the cert is issued against
`<dns-label>.<location>.cloudapp.azure.com`.

#### Scenario: Both PIPs are static Standard SKU with the documented DNS labels

- **WHEN** `04-Deploy-LlmPublicIp.ps1` completes successfully
- **THEN** both `pip-llm-vllm-<env>-<loc>-001` (IPv6) and
  `pipv4-llm-vllm-<env>-<loc>-001` (IPv4) exist with `sku.name=Standard`,
  `publicIPAllocationMethod=Static`, and the DNS labels
  `llm-<orgid>-<env>` and `llm-<orgid>-<env>-ipv4` respectively.

### Requirement: Persistent data disk SHALL be a standalone Managed Disk owned independently of any VM

`05-Deploy-LlmDataDisk.ps1` SHALL create a standalone Managed Disk named
`disk-llm-vllm-models-<env>-001` in the workload resource group with SKU
`StandardSSD_LRS` and size 8 GiB. The disk SHALL NOT be created via
`az vm create --data-disk-sizes-gb` or any other VM-bundled mechanism.

The script SHALL be idempotent: when the disk already exists, the script
SHALL exit 0 without modification. The script SHALL NOT resize, retype, or
re-tag an existing disk.

No script in this capability SHALL delete this disk. Removal of the disk is
the responsibility of `a-infrastructure/91-remove-workload-rg.ps1` (which
cascade-deletes the workload RG) or of explicit operator action outside
this capability.

#### Scenario: Disk is created with the documented attributes

- **WHEN** `05-Deploy-LlmDataDisk.ps1` runs against a clean RG
- **THEN** `az disk show` reports SKU `StandardSSD_LRS`, size `8` GiB,
  and the disk is in the `Unattached` state.

#### Scenario: Re-running 05 against an existing disk is a no-op

- **GIVEN** `disk-llm-vllm-models-dev-001` already exists with SKU
  `StandardSSD_LRS` and size 8 GiB
- **WHEN** `05-Deploy-LlmDataDisk.ps1` runs again with the same parameters
- **THEN** the script exits 0 and the disk is unchanged (same size, SKU,
  tags, and attachment state).

### Requirement: GPU VM SHALL be Standard_NC4as_T4_v3 Ubuntu 22.04 with the NVIDIA driver extension and the persistent data disk attached

`06-Deploy-LlmVm.ps1` SHALL create a single Linux VM:

- Size: `Standard_NC4as_T4_v3`.
- Image: Ubuntu 22.04 LTS (Canonical's `Ubuntu-2204` offering).
- Admin auth: SSH public key only (`--generate-ssh-keys` or operator-supplied
  key), never a password.
- Network: NIC attached to the subnet from `01-Deploy-LlmSubnet.ps1`, both
  PIPs from `04-Deploy-LlmPublicIp.ps1` attached.
- Identity: the UAMI from `03-Deploy-LlmIdentity.ps1` assigned via
  `--assign-identity`.
- Data disk: the existing `disk-llm-vllm-models-<env>-001` attached at LUN 0
  via `--attach-data-disks <disk-id>`. The script SHALL NOT use
  `--data-disk-sizes-gb` and SHALL NOT use any other flag that would create
  a new data disk.
- Custom data: the substituted cloud-init template (see template
  substitution requirement below).
- Auto-shutdown: configured via `az vm auto-shutdown` at a fixed UTC time
  (default `0900` UTC; overridable via `-ShutdownUtc`).
- NVIDIA GPU driver: applied via the NVIDIA GPU Driver Linux VM extension
  at create time.

The script SHALL pre-check `az vm list-usage` for the
`standardNCASv3Family` quota in the target region and fail with a clear
message before attempting to create the VM if the quota is zero.

The script SHALL pre-check that `disk-llm-vllm-models-<env>-001` exists and
is in the `Unattached` state OR is already attached to the same VM being
deployed; if it is `Attached` to a different VM, the script SHALL fail
with a clear message identifying the holder VM.

#### Scenario: Zero quota produces a clear error before VM creation is attempted

- **GIVEN** the subscription has zero quota for `standardNCASv3Family` in
  `-Location`
- **WHEN** `06-Deploy-LlmVm.ps1` is executed
- **THEN** the script writes a message indicating the quota issue and the
  region, exits non-zero, and does not call `az vm create`.

#### Scenario: VM is created with the data disk attached at LUN 0

- **GIVEN** quota is available and `disk-llm-vllm-models-<env>-001` exists
  and is unattached
- **WHEN** `06-Deploy-LlmVm.ps1` completes successfully
- **THEN** `az vm show` reports size `Standard_NC4as_T4_v3`, OS image
  `Canonical:0001-com-ubuntu-server-jammy:22_04-lts*`, the UAMI assigned,
  password authentication disabled, an auto-shutdown schedule configured,
  and the data disk listed in `storageProfile.dataDisks` at LUN 0.

#### Scenario: Disk attached to another VM produces a clear error

- **GIVEN** `disk-llm-vllm-models-<env>-001` is attached to a VM other than
  `vmllmvllm001`
- **WHEN** `06-Deploy-LlmVm.ps1` is executed
- **THEN** the script writes a message identifying the holder VM, exits
  non-zero, and does not call `az vm create`.

### Requirement: Cloud-init template SHALL be substituted via tokenised replacement

The deploy script SHALL read `c-workload/data/vllm-cloud-init.txt`, replace
the documented `#INIT_*#` tokens with their runtime values, write the
result to `c-workload/temp/vllm-cloud-init.txt~` (which SHALL be
gitignored), and pass that file as `--custom-data` to `az vm create`.

The substituted tokens SHALL be exactly:

| Token                           | Source                                      |
|---------------------------------|---------------------------------------------|
| `#INIT_HOST_NAME#`              | IPv6 PIP FQDN                               |
| `#INIT_HOST_NAME_IPV4#`         | IPv4 PIP FQDN                               |
| `#INIT_KEY_VAULT_NAME#`         | Shared Key Vault name                       |
| `#INIT_API_KEY_SECRET_NAME#`    | `vllm-api-key`                              |
| `#INIT_UAMI_CLIENT_ID#`         | UAMI `clientId`                             |
| `#INIT_CERT_EMAIL#`             | `-AcmeEmail` value                          |
| `#INIT_ACME_STAGING_FLAG#`      | empty (prod) or `--test-cert` (`-AcmeStaging`) |
| `#INIT_VLLM_VERSION#`           | Pinned vLLM version                         |
| `#INIT_SERVED_MODEL_NAME#`      | `qwen2.5-coder-7b`                          |
| `#INIT_MODEL_DIR_NAME#`         | `qwen2.5-coder-7b-awq`                      |
| `#INIT_MODEL_MOUNT_POINT#`      | `/opt/models`                               |

No secret values (API key, storage account keys, SAS tokens) SHALL be
substituted into cloud-init. The API key is fetched at boot from Key Vault
using the UAMI; the model bytes are fetched later by
`util/Download-LlmModelToDisk.ps1`.

#### Scenario: No secret material is embedded in cloud-init

- **WHEN** the deploy script writes the substituted cloud-init to
  `c-workload/temp/vllm-cloud-init.txt~`
- **THEN** the file does not contain the literal value of `vllm-api-key`,
  any storage account key, or any SAS signature.

### Requirement: Cloud-init SHALL format and persistently mount the data disk at /opt/models

The cloud-init template SHALL, at first boot:

- Wait for the data disk to appear as a block device.
- Run `mkfs.ext4 -L llm-models <device>` only if `blkid` reports the disk
  has no filesystem; SHALL NOT format an existing filesystem under any
  circumstances.
- Append exactly one entry to `/etc/fstab` (or assert one is already
  present): `LABEL=llm-models  /opt/models  ext4  defaults,nofail  0  2`.
- Run `mount -a`.
- Set ownership of `/opt/models` to `vllm:vllm`.

The cloud-init SHALL NOT mount the disk via `/dev/sdc` or
`/dev/disk/by-lun/0`; the mount SHALL be by filesystem label.

#### Scenario: Pre-formatted disk is mounted, not reformatted

- **GIVEN** the attached data disk already has an ext4 filesystem with
  label `llm-models` (i.e. it is being reattached after a VM rebuild)
- **WHEN** the VM boots and cloud-init runs
- **THEN** `mkfs.ext4` is not invoked, the disk is mounted at
  `/opt/models`, and any pre-existing files under `/opt/models/` are
  preserved.

#### Scenario: Mount survives reboot via fstab

- **GIVEN** the VM has booted once and `/opt/models` is mounted from the
  data disk
- **WHEN** the VM is rebooted
- **THEN** `/opt/models` is mounted from the same labelled disk after
  reboot without any explicit `mount` command being run by the operator.

### Requirement: vLLM SHALL run as a non-root systemd service binding port 443 via cap_net_bind_service, gated by ConditionPathExists

The cloud-init SHALL install vLLM into `/opt/vllm/.venv`, grant the venv's
Python binary `cap_net_bind_service`, create a `vllm` system user, install
a systemd unit `/etc/systemd/system/vllm.service` that runs as `User=vllm`,
sources `/etc/vllm/vllm.env`, and execs
`vllm.entrypoints.openai.api_server` with at minimum the flags
`--host ::`, `--port 443`, `--ssl-certfile`, `--ssl-keyfile`,
`--api-key ${VLLM_API_KEY}`, `--model`, `--served-model-name`,
`--tool-call-parser hermes`, `--enable-auto-tool-choice`, and
`--max-model-len 32768`.

The unit SHALL include
`ConditionPathExists=/opt/models/qwen2.5-coder-7b-awq/config.json` so that
it stays inactive (silently, no error) when the model has not yet been
loaded onto the data disk.

The cloud-init SHALL `systemctl enable` the unit but SHALL NOT
`systemctl start` it. Starting the unit is the responsibility of
`util/Download-LlmModelToDisk.ps1` after a successful model load.

`/etc/vllm/vllm.env` SHALL be mode `0600`, owned by `vllm:vllm`, and SHALL
contain `VLLM_API_KEY=<secret>` populated from Key Vault at first boot.

#### Scenario: vLLM unit is enabled but inactive on a fresh VM

- **GIVEN** cloud-init has just completed on a new VM and the data disk is
  empty
- **WHEN** an operator inspects the unit
- **THEN** `systemctl is-enabled vllm` reports `enabled`,
  `systemctl is-active vllm` reports `inactive`, and the most recent
  journal lines show the `ConditionPathExists` check failing without an
  error.

#### Scenario: Service is not running as root once started

- **GIVEN** the model has been loaded and `vllm.service` is active
- **WHEN** an operator inspects the running process
- **THEN** the `vllm.entrypoints.openai.api_server` process is owned by
  the `vllm` user, not root, and the listening socket on port 443 is held
  by that process.

#### Scenario: API key file is locked down

- **WHEN** an operator inspects `/etc/vllm/vllm.env` after first boot
- **THEN** the file mode is `0600`, the owner and group are `vllm`, and
  the file contains a `VLLM_API_KEY=` line whose value matches the
  current Key Vault secret.

### Requirement: Certbot SHALL obtain the certificate via HTTP-01 standalone with a deploy-hook restart

The cloud-init SHALL install `certbot`, request the initial Let's Encrypt
certificate via `certbot certonly --standalone --preferred-challenges http
--cert-name vllm-cert -d <ipv6-fqdn> -d <ipv4-fqdn> -n --agree-tos -m
<email>` (with `--test-cert` appended when `-AcmeStaging` was passed), and
install a deploy hook at
`/etc/letsencrypt/renewal-hooks/deploy/10-vllm-restart.sh`. The deploy hook
SHALL copy the renewed `fullchain.pem` and `privkey.pem` from the
`vllm-cert` lineage to `/etc/vllm/certs/server.pem` and
`/etc/vllm/certs/server.key`, set them mode `0600` owned by `vllm:vllm`,
and run `systemctl restart vllm`.

The cloud-init SHALL NOT add a custom `cron` or `systemd` timer for
renewal; the certbot Debian package's bundled `certbot.timer` SHALL drive
renewals.

#### Scenario: Initial cert issuance succeeds independent of model load

- **WHEN** cloud-init completes on first boot, before any model has been
  loaded
- **THEN** `/etc/vllm/certs/server.pem` and `/etc/vllm/certs/server.key`
  exist with mode `0600` owned by `vllm:vllm`, and the certbot lineage
  `vllm-cert` is present under `/etc/letsencrypt/live/`.

#### Scenario: Renewal triggers the deploy hook

- **GIVEN** certbot's renewal timer fires and renews the `vllm-cert`
  lineage
- **WHEN** the renewal completes successfully
- **THEN** the deploy hook copies the new cert and key into
  `/etc/vllm/certs/`, sets mode `0600` owned by `vllm:vllm`, and runs
  `systemctl restart vllm`.

### Requirement: Model load SHALL be a separate util script using `az vm run-command invoke`

`util/Download-LlmModelToDisk.ps1` SHALL execute on the operator's machine
and use `az vm run-command invoke --command-id RunShellScript` to run an
inline shell script on the LLM VM. The inline script SHALL:

- Short-circuit with a success exit if
  `/opt/models/qwen2.5-coder-7b-awq/config.json` is already present.
- Otherwise install `huggingface-hub` into the existing vLLM venv (`pip
  install -q`) and run `huggingface-cli download
  Qwen/Qwen2.5-Coder-7B-Instruct-AWQ --local-dir
  /opt/models/qwen2.5-coder-7b-awq --local-dir-use-symlinks False`.
- Set ownership of `/opt/models` to `vllm:vllm`.
- Run `systemctl start vllm` and verify `is-active` returns success;
  emit recent journal lines on failure.

The PowerShell wrapper SHALL accept `-Environment`, `-Location`,
`-ModelRepoId` (default `Qwen/Qwen2.5-Coder-7B-Instruct-AWQ`), and
`-ModelDirName` (default `qwen2.5-coder-7b-awq`) parameters with the
standard env-var fallbacks. It SHALL stream the run-command output back to
the operator.

The script SHALL NOT download model bytes through the operator's
workstation. The script SHALL NOT use Azure Storage or Blob.

#### Scenario: Re-running with model already present is a no-op

- **GIVEN** `/opt/models/qwen2.5-coder-7b-awq/config.json` is already
  present on the data disk
- **WHEN** `util/Download-LlmModelToDisk.ps1` is run
- **THEN** the script exits 0, no Hugging Face download is attempted, and
  `vllm.service` is started if it was not already active.

#### Scenario: Operator workstation never sees the bytes

- **WHEN** `util/Download-LlmModelToDisk.ps1` runs against a fresh VM with
  an empty data disk
- **THEN** the model files appear in `/opt/models/qwen2.5-coder-7b-awq/`
  on the VM and no model files are written to the operator's workstation
  filesystem.

### Requirement: Detach script SHALL deallocate, detach the data disk, and optionally delete the VM, while always preserving the disk

`util/Detach-LlmModelDisk.ps1` SHALL:

- Run `az vm deallocate` against `vmllmvllm001`. Idempotent against an
  already-deallocated or missing VM.
- Run `az vm disk detach` for `disk-llm-vllm-models-<env>-001`. Idempotent
  against an already-detached disk.
- When invoked with `-DeleteVm`, run `az vm delete --yes` against
  `vmllmvllm001`. Without `-DeleteVm`, leave the VM in deallocated state.

The script SHALL NOT delete the data disk under any flag. The script SHALL
NOT delete the OS disk except as a side effect of `az vm delete` (which
deletes the OS disk by default in modern `az` versions).

#### Scenario: Detach without -DeleteVm leaves the VM stopped and disk free

- **GIVEN** the LLM VM is running with the data disk attached
- **WHEN** `util/Detach-LlmModelDisk.ps1 -Environment Dev` is run (without
  `-DeleteVm`)
- **THEN** the VM is in `VM deallocated` state, the data disk is in
  `Unattached` state, the disk has not been deleted, and the model files
  on the disk are intact.

#### Scenario: Detach with -DeleteVm deletes the VM but preserves the disk

- **GIVEN** the LLM VM is running with the data disk attached
- **WHEN** `util/Detach-LlmModelDisk.ps1 -Environment Dev -DeleteVm` is run
- **THEN** the VM no longer exists, the OS disk no longer exists, the
  data disk is in `Unattached` state, the disk has not been deleted, and
  re-running `06-Deploy-LlmVm.ps1` re-attaches the same disk with the
  model files intact.

### Requirement: Smoke test SHALL validate /v1/models and tool-calling

`07-Test-LlmEndpoint.ps1` SHALL fetch the API key from the shared Key
Vault and the FQDN from the IPv6 PIP, then make exactly two HTTPS calls to
the public endpoint:

1. `GET /v1/models` with `Authorization: Bearer <key>`. The script SHALL
   assert the response status is 200 and that the `data[].id` array
   contains `qwen2.5-coder-7b`.
2. `POST /v1/chat/completions` with a single tool definition
   `get_weather(location: string)` and a user message asking about the
   weather. The script SHALL assert the response status is 200 and that
   `choices[0].message.tool_calls` is a non-empty array whose first entry
   has `function.name == "get_weather"`.

The script SHALL exit 0 only if both assertions pass. With `-AcmeStaging`,
the script SHALL emit a warning and use `-SkipCertificateCheck`; without
`-AcmeStaging`, default certificate validation SHALL apply (no skip flag).

The script's documentation SHALL state that
`util/Download-LlmModelToDisk.ps1` must have been run successfully at
least once before this test will pass.

#### Scenario: Both assertions pass against a healthy endpoint

- **GIVEN** the deployment is complete, the model has been loaded, and
  vLLM is serving with a valid Let's Encrypt production cert
- **WHEN** `07-Test-LlmEndpoint.ps1` runs without `-AcmeStaging`
- **THEN** the script reports both checks passing and exits 0, having
  made no use of `-SkipCertificateCheck`.

#### Scenario: Tool-call assertion failure exits non-zero

- **GIVEN** vLLM returns a chat completion with no `tool_calls` array
- **WHEN** `07-Test-LlmEndpoint.ps1` runs
- **THEN** the script writes a diagnostic message and exits non-zero.

### Requirement: Deploy scripts SHALL be idempotent

Deploy scripts MUST be idempotent. Re-running any deploy script with the
same parameters against a subscription where it has already succeeded
SHALL exit 0 and SHALL NOT produce errors, duplicate resources, or
mutations to existing resources. Each `create` operation SHALL be guarded
by a `show` pre-check.

#### Scenario: Re-running 01-Deploy-LlmSubnet is a no-op

- **GIVEN** `01-Deploy-LlmSubnet.ps1` has previously succeeded
- **WHEN** the same script is run again with the same parameters
- **THEN** it exits 0, the subnet is unchanged, the NSG is unchanged, the
  three inbound rules remain present and unmodified, and the subnet's
  NSG association is unchanged.

#### Scenario: Re-running 06-Deploy-LlmVm is a no-op

- **GIVEN** `06-Deploy-LlmVm.ps1` has previously succeeded and the VM is
  running with the data disk attached
- **WHEN** the same script is run again with the same parameters
- **THEN** it exits 0, the VM is not redeployed, the NIC is unchanged,
  the identity assignment is unchanged, the data disk remains attached at
  LUN 0, and no new auto-shutdown schedule is created.

### Requirement: Every resource SHALL carry CAF-aligned tags

Every resource SHALL carry the CAF-aligned tags listed below. The NSG,
public IPs, UAMI, data disk, NIC, and VM created by these scripts MUST
have the following tags applied:

| Tag                  | Value                       |
|----------------------|-----------------------------|
| `WorkloadName`       | `llm`                       |
| `ApplicationName`    | `llm-vllm`                  |
| `DataClassification` | `Non-business`              |
| `Criticality`        | `Low`                       |
| `BusinessUnit`       | `IT`                        |
| `Env`                | value of `-Environment`     |

#### Scenario: Tags are present on every created resource

- **WHEN** scripts 01–06 have all completed successfully
- **THEN** the NSG, both public IPs, the UAMI, the data disk, the NIC,
  and the VM each report all six tags with the specified values.

### Requirement: Operational utility scripts SHALL provide stop, start, and rotate without VM rebuild

`Stop-LlmVm.ps1` SHALL deallocate the VM via `az vm deallocate`.
`Start-LlmVm.ps1` SHALL start the VM via `az vm start`.
`Rotate-LlmApiKey.ps1` SHALL set a new `vllm-api-key` secret value in the
shared Key Vault and use `az vm run-command invoke` to rewrite
`/etc/vllm/vllm.env` and `systemctl restart vllm` so the VM picks up the
new key without a rebuild.

None of these scripts SHALL re-run cloud-init, recreate the VM, re-request
a Let's Encrypt certificate, or modify the data disk.

#### Scenario: Rotate-LlmApiKey updates the key without redeploying the VM

- **GIVEN** the VM is running and `vllm-api-key` is at version V1
- **WHEN** `Rotate-LlmApiKey.ps1` is run
- **THEN** `vllm-api-key` is at version V2 in Key Vault, the VM was not
  redeployed, the data disk was not modified, the `vllm` systemd unit was
  restarted, and the endpoint now accepts the V2 token and rejects V1.

### Requirement: The folder SHALL include a README documenting prerequisites, run order, model load, rebuild flow, and OpenCode wiring

`c-workload/README.md` SHALL document, at minimum: required tooling
(PowerShell 7+, Azure CLI, `az login`, Contributor on subscription, T4
quota), the prerequisite capabilities (`a-infrastructure/01..03`,
`b-shared/01..02`), the deploy run order (`01..06`), the post-VM model
load step (`util/Download-LlmModelToDisk.ps1`), the smoke-test step (`07`),
the operational utility scripts, the VM-rebuild flow that preserves the
data disk (`util/Detach-LlmModelDisk.ps1 -DeleteVm` followed by re-running
`06`), expected hostnames (with the OrgId/env substitution explained), an
OpenCode configuration snippet (or a pointer to
`docs/OpenCode-vllm-config.md`), the cost trade-offs of leaving the VM
running vs. deallocated, troubleshooting pointers (cloud-init log
location, vLLM systemd unit name, `ConditionPathExists` semantics, certbot
logs), the explicit acknowledgement that data-disk loss requires
re-pulling the model from Hugging Face, and a note that no `9x-Remove`
script exists in `c-workload/` (RG-level teardown is handled by
`a-infrastructure/91-remove-workload-rg.ps1`).

#### Scenario: README enables a new operator to run the scripts

- **WHEN** a new developer reads `c-workload/README.md`
- **THEN** they can identify which prerequisite capabilities to deploy
  first, the order to run the workload scripts, when and how to run
  `util/Download-LlmModelToDisk.ps1`, the FQDN that will be produced for
  a given subscription, how to wire the endpoint into OpenCode, how to
  rebuild the VM while preserving the model, and where teardown lives.
