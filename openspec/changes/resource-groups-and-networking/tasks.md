# Tasks

## 1. Folder and documentation

- [ ] 1.1 Create `a-infrastructure/` folder at the repository root.

## 2. Shared deploy script (01)

- [ ] 2.1 Create `a-infrastructure/01-init-shared-rg.ps1` with pwsh shebang, comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`, `.EXAMPLE`), `[CmdletBinding()]`, and `$ErrorActionPreference = 'Stop'`.
- [ ] 2.2 Add `param()` block with `-Environment` / `$env:DEPLOY_ENVIRONMENT` / default `Dev`, `-Location` / `$env:DEPLOY_LOCATION` / default `australiaeast`, and `-UlaGlobalId` / `$env:DEPLOY_GLOBAL_ID` / default = SHA256 of `az account show --query id -o tsv` truncated to 10 hex chars (match IOT reference exactly).
- [ ] 2.3 Derive shared IPv6 `fd<gg>:<gggg>:<gggggg>:0100::/64` and IPv4 `10.<gg>.1.0/24`; also derive shared IPv6/IPv4 prefixes (for reference/peering) and the shared RG/VNet names from the same params.
- [ ] 2.4 Create `rg-llm-shared-001` with the six CAF tags (`WorkloadName=llm`, `ApplicationName=llm`, `DataClassification=Non-business`, `Criticality=Low`, `BusinessUnit=IT`, `Env=<env>`); idempotent via `az group create`.
- [ ] 2.5 Create `vnet-llm-shared-<loc>-001` dual-stack with the two derived prefixes and the same six tags; idempotent via `az network vnet create`.
- [ ] 2.6 Emit `Write-Verbose` for each RG, VNet, and peering step.

## 2. Gateway deploy script (01)

- [ ] 3.1 Create `a-infrastructure/02-init-gateway-rg.ps1` with pwsh shebang, comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`, `.EXAMPLE`), `[CmdletBinding()]`, and `$ErrorActionPreference = 'Stop'`.
- [ ] 3.2 Derive gateway IPv6 `/64` (`fd<gg>:<gggg>:<gggggg>:0100::/64`) and IPv4 `/24` (`10.<gg>.1.0/24`) from `UlaGlobalId`.
- [ ] 3.3 Create `rg-llm-gateway-001` with the six CAF tags (`WorkloadName=llm`, `ApplicationName=llm`, `DataClassification=Non-business`, `Criticality=Low`, `BusinessUnit=IT`, `Env=<env>`); idempotent via `az group create`.
- [ ] 3.4 Create `vnet-llm-gateway-<loc>-001` dual-stack with the two derived prefixes and the same six tags; idempotent via `az network vnet create`.
- [ ] 3.5 Create peering `peer-shared-to-gateway` on the shared VNet with `--allow-vnet-access true --allow-forwarded-traffic true`, guarded by `az network vnet peering show ... 2>$null` to skip if present.
- [ ] 3.6 Create peering `peer-gateway-to-shared` on the gateway VNet with the same flags and guard.
- [ ] 3.7 Emit `Write-Verbose` for each RG and VNet step.

## 4. Workload deploy script (03)

- [ ] 4.1 Create `a-infrastructure/03-init-workload-rg.ps1` with the same header, params, and conventions as 01.
- [ ] 4.2 Derive workload IPv6 `fd<gg>:<gggg>:<gggggg>:0300::/64` and IPv4 `10.<gg>.3.0/24`; also derive gateway and shared RG/VNet names for peering.
- [ ] 4.3 Create `rg-llm-workload-<env>-001` and `vnet-llm-workload-<env>-<loc>-001` with CAF tags.
- [ ] 4.4 Create peerings `peer-workload-dev-to-gateway` (on workload VNet) and `peer-gateway-to-workload-dev` (on gateway VNet) with `--allow-vnet-access true --allow-forwarded-traffic true`, each guarded with `peering show`.
- [ ] 4.5 Create peerings `peer-workload-dev-to-shared` (on workload VNet) and `peer-shared-to-workload-dev` (on shared VNet) with `--allow-vnet-access true` only (forwarded-traffic default `false`), each guarded with `peering show`.
- [ ] 4.6 Emit `Write-Verbose` for each RG, VNet, and peering step.

## 5. Manual verification (not archived artifacts — ops sign-off)

- [ ] 5.1 Run scripts 01, 02, 03 against a development subscription; confirm three RGs, three VNets, and six peerings exist with the expected names, address prefixes, tags, and peering flags (`az network vnet peering list` for each VNet).
- [ ] 5.2 Re-run scripts 01, 02, 03 with the same parameters; confirm exit code 0, zero errors, and no resource mutations (idempotency check).
- [ ] 5.3 If available, run script 01 against a second subscription; verify its resolved `UlaGlobalId` differs from the first and the resulting address ranges do not overlap.

## 6. Cross-reference update

- [ ] 6.1 Update the top-level `README.md` section referencing the (previously aspirational) `corp-it/` folder to point at the now-existing `a-infrastructure/` folder and its script filenames.
