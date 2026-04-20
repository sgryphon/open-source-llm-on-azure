## Why

Business units cannot self-serve the foundational networking that a central IT group
controls: resource groups with IP-address allocations and inter-VNet peering. Without
these, no further work (VPN, shared services, workload VMs, LLM hosting) can start.
This change delivers the minimum "central IT" core so downstream work is unblocked,
while staying deliberately narrow — no subnets, NSGs, or services yet.

## What Changes

- Add top-level `a-infrastructure/` folder with sequentially numbered PowerShell
  scripts that call Azure CLI, matching the conventions of the linked IOT reference
  project.
- Create three resource groups, each with one dual-stack VNet (IPv4 + IPv6 ULA):
  gateway, shared, workload. VNet-level only — no subnets in this change.
- Create VNet peerings: gateway ↔ shared, gateway ↔ workload, shared ↔ workload.
  Peerings involving the gateway set `allow-forwarded-traffic=true` to permit future
  VPN transit.
- Derive IP address ranges from a hash of the subscription ID (ULA `/48`, IPv4
  `10.x.y.0/24`) so multiple subscriptions can coexist and peer without overlap.
- Follow CAF naming with `llm` as the workload/app token, e.g.
  `rg-llm-gateway-dev-001`, `vnet-llm-shared-dev-australiaeast-001`.

## Capabilities

### New Capabilities
- `core-infrastructure`: the central-IT-owned resource groups, VNets (with
  hash-derived dual-stack address ranges), and inter-VNet peerings that every other
  component in this project depends on. Covers naming, addressing, topology,
  tagging, and script conventions for this layer only.

### Modified Capabilities
<!-- None: no existing specs. -->

## Impact

- New code: `a-infrastructure/` (PowerShell scripts + README). No changes to existing
  code — repo currently has only documentation.
- New runtime dependencies (developer-side only): PowerShell 7+, Azure CLI, an
  authenticated `az login` session with Contributor on the target subscription.
- No Azure cost while scripts are unused; once run, resource groups and VNets are
  free of charge (peering traffic is not billed until data flows through it).
- Downstream changes (VPN, shared services, workload, LLM) will consume the RGs and
  VNets produced here. RBAC assignment (granting the business unit Contributor on
  `rg-llm-workload-...`) is intentionally deferred to a later change.
