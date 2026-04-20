# Design: core-infrastructure

## Context

The project README establishes that central IT owns resource groups, VNets, and
peering; business units consume those via Contributor rights on the workload RG.
This change implements that minimum, and nothing more. It is modelled directly on
the working `azure-landing/infrastructure/deploy-network.ps1` from the IOT demo
project (https://github.com/sgryphon/iot-demo-build), adapted from one VNet to
three (gateway / shared / workload) and using the project token `llm` so multiple
projects can coexist in a single subscription.

The repository currently contains only documentation; there is no existing code to
integrate with. Primary operator is a central-IT admin with Contributor on the
target subscription. Downstream consumers (future VPN, shared-services, workload
changes) will read the RGs and VNets produced here but are not in scope.

## Goals / Non-Goals

**Goals:**
- Deterministic, non-colliding IP ranges across multiple subscriptions so peered
  environments (e.g. prod + test) never overlap.
- Full IPv6 dual stack (Azure requires IPv4 alongside IPv6).
- CAF-compliant names with the project token `llm`.
- Idempotent scripts that can be re-run safely.
- Minimum viable surface: resource groups, VNets, peerings only.

**Non-Goals:**
- Subnets, NSGs, route tables, UDRs — the business unit and subsequent changes
  create these inside the workload VNet.
- VPN / ExpressRoute — separate future layer (`b-vpn/` or similar).
- Shared services (DNS, KeyVault, Monitor) — separate future layer.
- Multi-workload parameterisation — single literal `workload` role for now.
- RBAC assignment for the business unit — deferred to a later change.
- Resource locks on RGs — flagged as a follow-up, not in this change.

## Decisions

### D1. PowerShell wrapping Azure CLI (`az`), not the Az PowerShell module

Scripts are pwsh files that invoke `az` CLI for every Azure operation, matching
the IOT reference exactly.

Rationale: lowest-risk port from the working reference; one tool to install; `az`
is cross-platform; `az` commands are mostly idempotent so re-running is safe. The
blog post's preference for the Az PowerShell module (for object handling) is
acknowledged but unnecessary at this small surface (RGs, VNets, peering) where
no complex object manipulation is required.

**Alternatives considered:** Az PowerShell module (rejected — diverges from the
working reference with no benefit here); Bicep/ARM (rejected per the project
README and blog — migration scripts handle incremental change better than
desired-state templates at this layer); hybrid script+template (rejected —
moving parts without benefit at this scale).

### D2. Hash-based address allocation from subscription ID

Default `UlaGlobalId` is the first 10 hex characters of SHA256 of the subscription
ID, computed the same way as the IOT reference (`Get-FileHash` over a UTF-8
`MemoryStream` of the output of `az account show --query id --output tsv`).

This gives:
- IPv6 ULA `/48` per subscription, formed as `fd<gg>:<gggg>:<gggg>::/48`.
- IPv4 `10.<gg>.0.0/16` per subscription, where `<gg>` is the first byte of
  `UlaGlobalId` (interpreted as `[int]"0x.."`).

Two different subscriptions will (with overwhelming probability) get
non-overlapping ranges, so peering them later is safe. All three scripts accept
`-UlaGlobalId` / `$env:DEPLOY_GLOBAL_ID` to override when needed (forcing a known
range for testing, or resolving an observed collision).

**Alternatives considered:** manual IP assignment by the operator (rejected —
error-prone, no determinism across subscriptions); random allocation (rejected —
not reproducible, breaks idempotency).

### D3. Per-VNet address assignment within the `/48`

| Role     | VNet ID | IPv6 prefix                            | IPv4 prefix      |
|----------|---------|----------------------------------------|------------------|
| Gateway  | `0100`  | `fd<gg>:<gggg>:<gggg>:0100::/64`       | `10.<gg>.1.0/24` |
| Shared   | `0200`  | `fd<gg>:<gggg>:<gggg>:0200::/64`       | `10.<gg>.2.0/24` |
| Workload | `0300`  | `fd<gg>:<gggg>:<gggg>:0300::/64`       | `10.<gg>.3.0/24` |

IPv4 last octet of the subnet ID gives the third octet of the IPv4 `/24` (same
mechanism as the IOT reference: `[int]"0x$vnetId" -bAnd 0xFF`).

IPv6 uses `/56` ranges per vnet (allowing IPv6 subnets that are always `/64`)

IPv4 uses `/24` per VNet matches the IOT reference exactly. Tight, but this change creates
no subnets inside; later changes that carve subnets will use `/26` or `/27`
IPv4 inside (IPv6 `/64` stays per subnet).

**Alternatives considered:** `/20` per VNet (rejected in planning — user
preferred matching IOT reference exactly; can be revisited in a later change if
`/24` proves too tight).

### D4. Naming — CAF with `llm` as the workload/app token

All lowercase, CAF canonical order `<type>-<workload>-<role>-<env>[-<loc>]-<###>`:

| Kind    | Pattern                                   | Example                                   |
|---------|-------------------------------------------|-------------------------------------------|
| RG      | `rg-llm-<role>-<env>-<###>`               | `rg-llm-gateway-dev-001`                  |
| VNet    | `vnet-llm-<role>-<env>-<loc>-<###>`       | `vnet-llm-shared-dev-australiaeast-001`   |
| Peering | `peer-llm-<srcRole>-<env>-to-<dstRole>-<env>`   | `peer-llm-workload-dev-to-gateway`        |

For this example, lets' not give `gateway` an environment (it's already distinguished by llm), which better reflects to usual structure (e.g. a single ExpressRoute so your desktop has access to all related networks). Yes, some cases might use a separate VPN for dev, but lets not worry about that.

Shared services are also similar, and will not have an environment (so just `rg-llm-shared-001`). I know this is more likely to be different, but keep it simple for now.

Roles: `gateway`, `shared`, `workload`. No global-uniqueness token (e.g. `OrgId`)
is needed because RGs are subscription-scoped and VNets are RG-scoped — neither
kind lives in a global namespace. A uniquifier will be added in later changes for>
globally-named resources (Key Vault, Storage, etc.).

### D5. Peering topology and flags

```
    gateway  <--- allow-forwarded-traffic --->  shared
       ^                                           ^
       |                                           |
       | allow-forwarded-traffic                   | (defaults)
       v                                           v
               workload  <------------------->
                         (defaults)
```

All peerings bidirectional (two peering halves per pair).
`--allow-vnet-access true` on every half.
`--allow-forwarded-traffic true` on the four gateway-side halves (gateway↔shared
both ways, gateway↔workload both ways) so that when a VPN arrives later, its
traffic can transit the gateway VNet to the spokes.
`--use-remote-gateways` / `--allow-gateway-transit` stay at defaults (`false`)
until a VPN gateway exists; flipping them is a job for the VPN change, not this
one.

**Alternatives considered:** hub-spoke only (gateway↔shared and gateway↔workload,
no direct shared↔workload) — rejected because shared services (DNS, Monitor) will
want direct, low-latency paths to workload VNets without hairpinning through the
gateway.

### D6. Idempotency strategy

- `az group create` and `az network vnet create` are idempotent (re-run returns
  the existing resource unchanged).
- `az network vnet peering create` fails if the peering already exists. Guard:
  check `az network vnet peering show ... 2>$null` before create, skip if present.
- Overall: every deploy script can be re-run to completion with zero errors and
  zero mutations when the target state already matches.

### D7. Tagging (CAF-aligned)

Applied to every RG and VNet:

| Tag                  | Value                    |
|----------------------|--------------------------|
| `WorkloadName`       | `llm`                    |
| `ApplicationName`    | `llm`                    |
| `DataClassification` | `Non-business`           |
| `Criticality`        | `Low`                    |
| `BusinessUnit`       | `IT`                     |
| `Env`                | value of `-Environment`  |

### D8. Script numbering: 01–03 for deploy

Deploy scripts `01`, `02`, `03` reflect strict dependency order (shared peers to
gateway, workload peers to both). This matches the
scripted-migration philosophy from the blog: each step runnable independently
after its dependencies, easy per-step retry, easy code review.

## Risks / Trade-offs

- [`/24` per VNet is tight for real subnetting later] → Acceptable now because
  this change creates no subnets; revisit in a dedicated change if hit. Workload
  subnets can fit in `/26`/`/27` chunks.
- [Hash collision across subscriptions produces overlapping ULA ranges] →
  Statistically negligible for a 10-hex-char (40-bit) prefix across any realistic
  number of subscriptions. Mitigation: `-UlaGlobalId` override documented in the
  README and accepted by every script.
- [`az network vnet peering create` not idempotent] → Explicit `peering show`
  guard before create in scripts 02 and 03.
- [No RBAC delegation to business unit] → Operator is assumed to be central IT;
  business-unit access is a later change. Teardown scripts require the same
  central-IT operator.
- [No resource lock on RGs, so accidental delete is possible] → Acceptable for a
  dev-focused first pass; IOT reference also lists locks as a "to do".
- [Peering-with-forwarded-traffic requires later VPN work to not re-peer] →
  Because forwarded traffic is already allowed, the VPN change only needs to flip
  `UseRemoteGateways` / `AllowGatewayTransit` on existing peerings, not recreate
  them.

## Migration Plan

Greenfield — no existing infrastructure to migrate from. Initial deployment:

1. Operator runs `az login` and sets target subscription context.
2. Operator runs `a-infrastructure/01-deploy-gateway-rg-vnet.ps1`.
3. Operator runs `a-infrastructure/02-deploy-shared-rg-vnet.ps1`.
4. Operator runs `a-infrastructure/03-deploy-workload-rg-vnet.ps1`.
5. Operator validates: three RGs, three VNets, six peerings present with correct
   addresses, tags, and peering flags.

Per-subscription re-run is a no-op (idempotent). Adding a second subscription
(e.g. prod) requires no code change — the hash-based addressing produces a
different `/48` automatically.

## Open Questions

- Should a minimum default subnet be created in each VNet to make them immediately
  useful, or is a VNet-only first pass clearer? Current answer: VNet-only, per
  user direction; reconsider if it turns out to be awkward in downstream changes.
- Resource lock on RGs — add now, or defer to a follow-up change? Current answer:
  defer, matching the IOT reference.
- Should `-ProjectPrefix` be a parameter (defaulting to `llm`) rather than a
  hard-coded literal, to make the scripts trivially reusable for another project?
  Current answer: literal `llm` for now to keep scripts concrete and match the
  single-project scope; revisit only if a second project actually lands in this
  repo.
