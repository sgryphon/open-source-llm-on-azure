# core-infrastructure

## Purpose

Defines the foundational Azure resource groups, virtual networks, and peering
topology that host the open-source LLM workload. This capability owns the
scripts in `a-infrastructure/` that provision three resource groups (gateway,
shared, workload), each containing a single dual-stack IPv4 + IPv6-ULA VNet,
fully peered in a triangle topology, and the matching removal scripts.

## Requirements

### Requirement: Scripts SHALL live in `a-infrastructure/` with sequential numeric prefixes

A top-level folder named `a-infrastructure/` SHALL contain all scripts for this
capability. Deploy scripts SHALL be numbered `01`, `02`, `03` in dependency order.
Removal scripts SHALL be numbered `91`, `92`, `93` in reverse dependency order.

#### Scenario: Directory listing shows scripts in execution order

- **WHEN** a developer runs `ls a-infrastructure/`
- **THEN** deploy scripts appear in numeric order as `01-deploy-gateway-rg-vnet.ps1`,
  `02-deploy-shared-rg-vnet.ps1`, `03-deploy-workload-rg-vnet.ps1`, followed by
  removal scripts `91-remove-workload-rg.ps1`, `92-remove-shared-rg.ps1`,
  `93-remove-gateway-rg.ps1`, and a `README.md`.

### Requirement: Scripts SHALL be PowerShell invoking Azure CLI

Every script SHALL start with `#!/usr/bin/env pwsh`, use `[CmdletBinding()]`,
typed `param()` blocks, `$ErrorActionPreference = 'Stop'`, and use `az` CLI
commands for all Azure operations. Every script SHALL include PowerShell
comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`, and at least one
`.EXAMPLE` section. Each significant step SHALL emit `Write-Verbose` output so
that setting `$VerbosePreference = 'Continue'` produces a readable trace.

#### Scenario: Script help is discoverable

- **WHEN** a developer runs `Get-Help ./a-infrastructure/01-deploy-gateway-rg-vnet.ps1 -Full`
- **THEN** synopsis, description, notes, parameter descriptions, and at least one
  example are displayed.

#### Scenario: Verbose output traces major steps

- **GIVEN** `$VerbosePreference = 'Continue'`
- **WHEN** any deploy script is executed
- **THEN** a `VERBOSE:` line is emitted for each resource group, virtual network,
  and peering create operation.

### Requirement: Scripts SHALL accept standard parameters with environment-variable fallbacks

Every deploy script SHALL accept at minimum the following parameters, each with
an environment-variable fallback and the specified default:

| Parameter      | Env var fallback     | Default                                                |
|----------------|----------------------|--------------------------------------------------------|
| `-Environment` | `DEPLOY_ENVIRONMENT` | `Dev`                                                  |
| `-Location`    | `DEPLOY_LOCATION`    | `australiaeast`                                        |
| `-UlaGlobalId` | `DEPLOY_GLOBAL_ID`   | first 10 hex chars of SHA256 of `az account show` id   |

Every removal script SHALL accept at minimum `-Environment` with fallback
`DEPLOY_ENVIRONMENT` and default `Dev`.

#### Scenario: Default UlaGlobalId is derived from the current subscription

- **GIVEN** `-UlaGlobalId` is not passed and `$env:DEPLOY_GLOBAL_ID` is not set
- **WHEN** a deploy script starts
- **THEN** it computes a 10-hex-character value by hashing the output of
  `az account show --query id --output tsv` with SHA256 and taking the first ten
  characters, matching the IOT reference implementation.

#### Scenario: Environment variable overrides default

- **GIVEN** `$env:DEPLOY_ENVIRONMENT = 'Prod'` and no `-Environment` argument
- **WHEN** a deploy script runs
- **THEN** it uses `Prod` as the environment value in resource names and tags.

### Requirement: Resource group names SHALL follow the pattern `rg-llm-<role>-<env>-<###>`

All resource group names SHALL be lowercase and of the form
`rg-llm-<role>-<env>-001`, where `<role>` is one of `gateway`, `shared`, or
`workload`, and `<env>` is the lowercased value of `-Environment`.

#### Scenario: Gateway RG name in Dev

- **WHEN** `01-deploy-gateway-rg-vnet.ps1` runs with `-Environment Dev`
- **THEN** the resource group created is named `rg-llm-gateway-dev-001`.

#### Scenario: Shared RG name in Prod

- **WHEN** `02-deploy-shared-rg-vnet.ps1` runs with `-Environment Prod`
- **THEN** the resource group created is named `rg-llm-shared-prod-001`.

### Requirement: VNet names SHALL follow the pattern `vnet-llm-<role>-<env>-<loc>-<###>`

All VNet names SHALL be lowercase and of the form
`vnet-llm-<role>-<env>-<location>-001`, where `<location>` is the lowercased
value of `-Location` (e.g. `australiaeast`, no dashes).

#### Scenario: Shared VNet name in Dev / australiaeast

- **WHEN** `02-deploy-shared-rg-vnet.ps1` runs with `-Environment Dev -Location australiaeast`
- **THEN** the VNet created is named `vnet-llm-shared-dev-australiaeast-001`.

### Requirement: Each VNet SHALL be dual-stack IPv4 + IPv6 ULA with deterministic addressing

Each VNet SHALL be created with exactly two address prefixes, an IPv4 `/24` and
an IPv6 ULA `/64`, derived deterministically from `UlaGlobalId` (written as ten
hex characters `gg gggg gggggg`):

| Role     | "VNet ID" | IPv6 prefix                              | IPv4 prefix      |
|----------|-----------|------------------------------------------|------------------|
| Gateway  | `0100`    | `fd<gg>:<gggg>:<gggggg>:0100::/64`       | `10.<gg>.1.0/24` |
| Shared   | `0200`    | `fd<gg>:<gggg>:<gggggg>:0200::/64`       | `10.<gg>.2.0/24` |
| Workload | `0300`    | `fd<gg>:<gggg>:<gggggg>:0300::/64`       | `10.<gg>.3.0/24` |

`<gg>` in the IPv4 prefix is the integer value of the first two hex characters of
`UlaGlobalId` (i.e. `[int]"0x$($UlaGlobalId.Substring(0,2))"`). The IPv4 third
octet is the low byte of the VNet ID (`0x00 = 1`, `0x00 = 2`, `0x00 = 3` in the
reference implementation uses the subnet-id low byte pattern from the IOT
script).

#### Scenario: Address ranges are deterministic given a UlaGlobalId

- **GIVEN** `UlaGlobalId` resolves to `abcdef0123`
- **WHEN** all three deploy scripts run
- **THEN** the gateway VNet has prefixes `fdab:cdef:0123:0100::/64` and
  `10.171.1.0/24` (0xab = 171), shared has `fdab:cdef:0123:0200::/64` and
  `10.171.2.0/24`, and workload has `fdab:cdef:0123:0300::/64` and
  `10.171.3.0/24`.

#### Scenario: Different subscriptions produce non-overlapping ranges

- **GIVEN** two subscriptions whose SHA256 hashes differ in the first byte
- **WHEN** script 01 is run against each
- **THEN** the two gateway VNets have different IPv4 `10.x.y.0/24` prefixes and
  different IPv6 `fd..` prefixes, enabling safe peering between them without IP
  overlap.

### Requirement: Scripts SHALL NOT create subnets, NSGs, or any other Azure resources

Scripts in this capability SHALL NOT create subnets, network security groups,
route tables, public IPs, VMs, Azure Functions, storage accounts, or any other
Azure resources. Scope is strictly limited to resource groups, VNets, and VNet
peerings.

#### Scenario: Clean subscription contains only RGs, VNets, and peerings after full deploy

- **GIVEN** a subscription with no pre-existing resources
- **WHEN** scripts 01, 02, and 03 have all completed
- **THEN** the subscription contains exactly three resource groups, each with one
  VNet, and six peering halves, and no other Azure resources have been created by
  these scripts.

### Requirement: Peering topology SHALL connect all three VNets bidirectionally

Scripts SHALL create six VNet peerings, covering all three pairs bidirectionally:
gateway↔shared, gateway↔workload, and shared↔workload. Each peering half SHALL
be named `peer-<srcRole>-to-<dstRole>` (e.g. `peer-workload-to-gateway`).

#### Scenario: All three pairs are peered after script 03 completes

- **WHEN** scripts 01, 02, and 03 have all completed
- **THEN** listing peerings across the three VNets shows six entries named
  `peer-gateway-to-shared`, `peer-shared-to-gateway`,
  `peer-gateway-to-workload`, `peer-workload-to-gateway`,
  `peer-shared-to-workload`, and `peer-workload-to-shared`.

### Requirement: Peerings connecting the gateway SHALL allow forwarded traffic

Peering halves connecting the gateway VNet to a spoke VNet (both directions) SHALL be created with `--allow-forwarded-traffic true`. Peering halves between shared and workload SHALL use the default (`false`). Every peering half SHALL have `--allow-vnet-access true`.

#### Scenario: Gateway-involving peerings allow forwarded traffic

- **WHEN** scripts 02 and 03 have run
- **THEN** `peer-gateway-to-shared`, `peer-shared-to-gateway`,
  `peer-gateway-to-workload`, and `peer-workload-to-gateway` all have
  `allowForwardedTraffic=true`, while `peer-shared-to-workload` and
  `peer-workload-to-shared` have `allowForwardedTraffic=false`.

#### Scenario: All peerings allow vnet access

- **WHEN** any deploy script creates a peering
- **THEN** that peering has `allowVirtualNetworkAccess=true`.

### Requirement: Deploy scripts SHALL be idempotent

Re-running any deploy script against a subscription where it has already succeeded SHALL complete with exit code 0 and SHALL NOT produce errors, duplicates, or mutations to the existing resource group, VNet, or peerings. Peering creation SHALL be guarded by a `peering show` check so that pre-existing peerings are skipped rather than recreated.

#### Scenario: Re-running a deploy script is a no-op

- **GIVEN** `02-deploy-shared-rg-vnet.ps1` has previously succeeded
- **WHEN** the same script is run again with the same parameters
- **THEN** the script exits with code 0, the resource group is unchanged, the
  VNet is unchanged, and both peering halves (`peer-shared-to-gateway` and
  `peer-gateway-to-shared`) remain present and unmodified.

### Requirement: Every RG and VNet SHALL carry CAF-aligned tags

Every resource group and VNet created by these scripts SHALL have the following
tags applied:

| Tag                  | Value                   |
|----------------------|-------------------------|
| `WorkloadName`       | `llm`                   |
| `ApplicationName`    | `llm`                   |
| `DataClassification` | `Non-business`          |
| `Criticality`        | `Low`                   |
| `BusinessUnit`       | `IT`                    |
| `Env`                | value of `-Environment` |

#### Scenario: Tags are present on every created resource

- **WHEN** any deploy script completes successfully
- **THEN** `az group show` for the created RG and `az network vnet show` for the
  created VNet both report all six tags with the specified values.

### Requirement: Removal scripts SHALL tear down resource groups in reverse dependency order

Removal scripts SHALL each delete their respective resource group (and its
contents, including the VNet and its peering halves, via Azure's cascade
delete). They SHALL accept `-Environment` and SHALL operate without interactive
confirmation (using `--yes` on `az group delete`).

- `91-remove-workload-rg.ps1` deletes `rg-llm-workload-<env>-001`.
- `92-remove-shared-rg.ps1` deletes `rg-llm-shared-<env>-001`.
- `93-remove-gateway-rg.ps1` deletes `rg-llm-gateway-<env>-001`.

#### Scenario: Full teardown leaves no capability-created resources

- **GIVEN** scripts 01, 02, and 03 have previously deployed resources for
  `-Environment Dev`
- **WHEN** scripts 91, 92, and 93 are run in order with `-Environment Dev`
- **THEN** `rg-llm-workload-dev-001`, then `rg-llm-shared-dev-001`, then
  `rg-llm-gateway-dev-001` are deleted, and no resources created by this
  capability remain in the subscription.

### Requirement: The folder SHALL include a README documenting prerequisites, addressing, and usage

`a-infrastructure/README.md` SHALL document, at minimum: required tooling
(PowerShell 7+, Azure CLI, `az login`, Contributor on subscription), the run
order for deploy and removal scripts, the addressing model with a worked example
showing resolved IPv4 and IPv6 ranges for a sample `UlaGlobalId`, the naming
convention table, the tagging table, the peering topology, and the teardown
order.

#### Scenario: README enables a new operator to run the scripts

- **WHEN** a new developer reads `a-infrastructure/README.md`
- **THEN** they can identify which tools to install, the order to run deploy
  scripts, the IP ranges that will be produced for a given subscription, the
  tags that will be applied, and how to tear everything down.
