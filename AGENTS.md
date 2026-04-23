# AGENTS.md

Guidance for AI coding agents and new contributors. Deliberately short. See
[`README.md`](README.md) for what the project *does*; this file is about *how we build it*.

## Workflow

Non-trivial changes go through **OpenSpec** (`openspec/changes/…`). Operators
drive it via the `/opsx-*` commands; an agent's job is usually to fill in the
artifacts faithfully, not to invoke the workflow. Obvious fixes (typos, comments,
clearly broken code) — just do them.

## Tooling

PowerShell 7+ and Azure CLI, run inside the devcontainer. Azure CLI only for
Azure operations — not the `Az` PowerShell module, and not Bicep/Terraform
embedded in these scripts (migration-style, forward-only; rationale in README).

## Script conventions

Applies to every `.ps1` in `a-infrastructure/`, `b-shared/`, `c-workload/`:

- `#!/usr/bin/env pwsh`, `[CmdletBinding()]`, `$ErrorActionPreference = 'Stop'`.
- Comment-based help: `.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`, `.EXAMPLE`.
- `Write-Verbose` on every significant step — an operator running with
  `$VerbosePreference = 'Continue'` should see a readable trace.
- Every `param()` has an env-var fallback (`$ENV:DEPLOY_*`) and a default.
- Scripts numbered in dependency order: deploy `01..99`.
- **Idempotent.** Re-running must not error and must not duplicate resources.
  Guard `create` calls with a `show` pre-check. Removal uses `--yes`.

## Naming and tagging

Follow Azure CAF:
[naming](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming),
[tagging](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging).

Project addition: an `OrgId` suffix ("0x" + first 4 hex chars of the subscription id)
on globally-unique names, such as DNS exposed names, so different subscriptions don't collide.

## Networking

Dual-stack IPv6 + IPv4 everywhere. Azure requires IPv4 alongside IPv6 (no
single-stack v6), but otherwise design v6-first.

Addressing is **deterministic, derived from the subscription id**. `UlaGlobalId`
is the first 10 hex chars of `SHA256(az account show --query id)`, decomposed
as `gg gggg gggg`. Vnet ranges are:

- IPv6: `fd<gg>:<gggg>:<gggg>:<vv>00::/56` (ULA, [RFC 4193](https://datatracker.ietf.org/doc/html/rfc4193))
- IPv4: `10.<gg>.<vv>.0/24` (`<gg>` as decimal)

where `<vv>` is a two-hex-digit VNet id.

Subnets are:

- IPv6: `fd<gg>:<gggg>:<gggg>:<vv><ss>::64` (ULA)
- IPv4: `10.<gg>.<vv>.s0/27` (`<gg>`, `<vv>` as decimal)

Where `<ss>` is a two-hex-digit subnet id (IPv6 is always /64).

IPv4 is a bit tricky to determine. For simplictly we assign /24 to vnets, but that 
means subnets are /26 to /28, depending on how many we need, and how many addresses in each.

Different subscriptions get non-overlapping ranges automatically, enabling safe
peering. Never hardcode addresses; always derive.

### IPv6 notes (common pitfalls)

- **Subnets are always `/64`.** SLAAC, privacy addresses
  ([RFC 4941](https://datatracker.ietf.org/doc/html/rfc4941)), and neighbour
  discovery all assume a 64-bit interface id. Smaller subnets break things.
- **IPv6 space is not sparse.** Don't subnet defensively "to save addresses" —
  a `/64` is the atom; a `/56` is how many atoms you hand out. Plenty for any
  subscription.
- Distinguish a **subnet** (routing / firewall scope, always `/64`) from an
  **allocation range** inside it (e.g. a DHCPv6 / VPN pool — narrower, purely
  a convenience).
- Azure limitations: some features are IPv4-only; `az` CLI cannot create
  `Icmpv6` NSG rules (workaround noted in `b-shared/04-Deploy-GatewaySubnet.ps1`).

## Secrets and private material

- `./temp/` at the repo root is **gitignored**; it holds generated keys, certs,
  PKCS#12 bundles, and cloud-init files with substituted values. Never commit
  anything from `./temp/`.
- Key Vault is the canonical store for anything that needs to cross machines.
  Upload idempotently (`az keyvault secret show` pre-check).
- Scripts accept secrets via parameter or env var, never via a file checked
  into the repo.

## Folder map

| Path                 | Contents                                           |
|----------------------|----------------------------------------------------|
| `a-infrastructure/`  | RGs, VNets, peering (corporate-IT scope)           |
| `b-shared/`          | Shared services: Key Vault, Monitor, VPN gateway   |
| `c-workload/`        | LLM VM, test function, workload-specific resources |
| `util/`              | One-shot helpers (e.g. RG teardown)                |
| `openspec/`          | Specs and in-flight changes                        |

## Don'ts

- Don't single-stack IPv4. Don't hardcode addresses.
- Don't commit anything from `./temp/`.
- Don't use the `Az` PowerShell module. Don't add Bicep/Terraform to these
  scripts without a design discussion.
- Don't introduce desired-state tooling — this project is migration-style.
- Don't create resources a script doesn't explicitly own (each script's scope
  is the resources it creates, nothing more).
