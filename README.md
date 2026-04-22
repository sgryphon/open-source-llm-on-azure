# Open Source LLM's in your Azure tennant

Blueprints for deploying open source LLMs on Azure.

## Goal

Connect your local AI tools to an open source LLM, run in a private environment on Azure, without sending data or code ourside your Azure tenant or to any third party.

## Solution components

### Open source large language model (LLM)

An LLM hosted in Azure, fully within your own tennant. Running this can be expensive.

You local AI tools connect, via your private connection, to your LLM.

### Agentic harness

As well as local development, provide sandbox environments with supporting services to run agents on Azure resources.

## Pre-requisites

### Azure resource group and networking

Your IT provider needs to provide an Azure resource group, with permissions for you to create the LLM in, and allocate networking addresses, with internal routing, to a virtual network (vnet) that you can use.

Sometimes they will lock things down a bit more and also control subnets and security groups.

In a cloud native organisation they may have self-service for a business unit to create an entire subscription, and then self-service network provisioning (with the required routing back to the corporate network).

### Private network connection to your development box

Often this is a virtual private network (VPN) between your local machine and Azure, although in some cases it could just be a public endpoint and relay on zero-trust transport layer security (TLS).

In an office environment it may mean a dedicated ExpressRoute service between your corporate network and Azure.

### Optional shared services

Services such as DNS are usually shared, as are core services like KeyVault and Azure Monitor.

You can duplicate them in your own subscription, or resource group, but shared is more common.

## Scripted deployment

...

----

# WIP:


## Open source models

- Deepseek
- Llama
- GPT-OSS
- Mistral
- Gemma
- MiniMax
- Kimi
- Qwen
- GLM

Some models available on foundary; others need VM.

https://www.bentoml.com/blog/navigating-the-world-of-open-source-large-language-models

- Cheap low cost model as proof of concept

- How do local tools connect to models? Is there an open protocol? Which tools support it?

- Need a separate example test container, that has a tool, and can be used to validate connectivity.

## General concepts

- Support IPv6 (only VM; foundary does not)
- Use a unique prefix/token, i.e. so can run in different Azure subscriptions without naming conflicts (i.e. use for global namespaces)
  - An example of this is in https://github.com/sgryphon/iot-demo-build (based on subscription ID prefix; I've also seen some Microsoft scripts with 'unique' (hash) calcs)
    - Note that the iot demo scripts also allocate network ranges based on prefixes, e.g. so you can have both a prod and test range.
    - Follow official MS well architected naming rules (note that many examples, including from MS, do not follow the rules)
- All infrastructure is scripted
  - I like migrations, because I don't trust desired state
  - I've learned the lesson too many times with databases
  - There are simply changes where A->B->C can not be determine from only A,C (mathematical reality).
  - Examples of this are in the IOT project
  - Also, this blog article: https://sgryphon.gamertheory.net/2021/12/azure-cli-vs-powershell-vs-arm-vs-bicep/
- Diagrams for deployment architecture
  - Use PlantUML (with C4 and Azure standard libraries for diagrams)

- Just deliver as scripts, or bicep, or mix, or what about a blueprint?
- Blueprints are deprecated; move to Template Specs and Deployment Stacks.

## Azure components

- Landing Zone + Workload

### Landing zone / shared services and networking

- Local computer, VPN endpoint?
- VPN ingress at Azure
- Gateway resource group, with gateway network (& subnet) to hold the VPN exit point.
- Workload resource group, with workload network
- Peering from the gateway network to the workload network
- The work resource group and workload network (specifially the workload network IP addresses) will usually be provisioned by a central IT group. They need to configure routing, assign addresses from a pool, and configure peering.
- Other things inside the workload resource group (or groups) can be handled by the business unit
- e.g. deploy a subnet, etc.

### Workload

- Workload subnet
- Private endpoints for resources
  - So that end user can connect via internal networks only to the LLM
- Some sort of test function, either a test VM, or test serverless Azure Function or similar that returns a /version endpoint that shows the current deployed version of the blueprint (also to test connectivity)

- Deploy as a VM (with GPU) ?
  - Selection of model
  - Download and install of model
  - How do we configure weights
    - What is hugging face?

- Does Microsoft Foundary support BYO open source LLM?
  - Most recent version of foundary doco: https://learn.microsoft.com/en-us/azure/foundry/what-is-foundry

## Solution components

Migration-style deployment: sequential PowerShell scripts deploying Bicep files, split by ownership boundary. Each step can be run independently after its dependencies.

VNet peering automatically exchanges routes for VNet address ranges — no UDRs needed at the infra level. The only UDR required is for the VPN client virtual IP pool (not part of any Azure VNet), deployed with the VPN step. Peering needs `allowForwardedTraffic: true` on the workload side for VPN traffic to traverse.

### Corporate IT (infra)

Creates resource groups, VNets, and peering. Controls network topology and address space. Business unit gets Contributor on their workload RG (which contains the VNet, so they can create subnets).

```
a-infrastructure/
  01-init-shared-rg.ps1               # Shared RG + VNet
  02-init-gateway-rg.ps1              # Gateway RG + VNet + peering shared <-> gateway
  03-init-workload-rg.ps1             # Workload RG + VNet + peerings to gateway & shared
                                      # Repeatable per workload. Business gets Contributor on RG.
```

### VPN (packaged separately)

Normally corporate IT owns connectivity (ExpressRoute, S2S VPN). Here it's a standalone DIY component, swappable between strongSwan / Azure VPN Gateway / WireGuard.

```
b-shared/
  04-Deploy-Certificate.ps1           # CA + server + initial client certs -> Key Vault
  05-Deploy-StrongSwanVm.ps1          # VM, public IPs, IP forwarding, NSG (UDP 500+4500)
vpn/
  03-client-routes.ps1                # UDR on workload subnet(s) for VPN client pool (future)
```

Run order: `b-shared/01..03` -> `b-shared/04-Deploy-Certificate.ps1` -> `b-shared/05-Deploy-StrongSwanVm.ps1`. `05` requires `-VpnUserPassword` (env `DEPLOY_VPN_USER_PASSWORD`) for the EAP-MSCHAPv2 credential.

### Shared services

Often also corporate IT, but not strictly required. Could be owned by a business unit.

```
shared-services/
  01-dns-zones.ps1                    # Private DNS Zone(s) + links to all VNets
  02-keyvault.ps1                     # Key Vault (certs, API keys)
  03-monitor.ps1                      # Log Analytics workspace + diagnostic settings
```

### Business workload

Fully owned by the business unit, deployed into the workload RG that IT provisioned.

```
workload/
  01-subnet-nsg.ps1                   # Subnet(s) + NSG rules
  02-test-function.ps1                # Test Azure Function + private endpoint
                                      # Returns /version, validates connectivity
  03-llm-vm.ps1                       # GPU VM + model download + vLLM/Ollama serving
                                      # Replaceable per model
```

### Summary

| Category | Scope | Key resources | Owner |
|----------|-------|---------------|-------|
| Corp IT | Gateway RG | RG, VNet | IT |
| Corp IT | Shared Services RG | RG, VNet, peering | IT |
| Corp IT | Workload RG (×n) | RG, VNet, peering | IT (business gets Contributor) |
| VPN | Gateway RG | strongSwan VM, public IP, certs, UDR | Separate (swappable) |
| Shared Services | Shared Services RG | DNS zones, Key Vault, Monitor | IT or business |
| Workload | Workload RG (×n) | Subnet, NSG, GPU VM, model, test function | Business unit |

## VPN options

Need a private connection from local machine (e.g. home) to the Azure VNet, so that local AI tools can connect to the LLM endpoint without going over the public internet. No need to own any IP addresses — all options work behind NAT / dynamic home IPs.

### strongSwan on an Azure VM (chosen)

IKEv2 VPN server running on a small Linux VM (e.g. B1s ~$4/month) inside the VNet. Clients use the native IKEv2 VPN client built into Windows, macOS, and Linux — no app install required. Certificate-based authentication.

- Full IPv6 dual-stack support (transport and tunnel)
- Native OS clients on all platforms (Windows, macOS, Linux)
- EAP-MSCHAPv2 and EAP-TLS support for flexible client auth
- Built-in virtual IP pool management (IPv4 + IPv6)
- Azure docs recommend strongSwan for Linux IKEv2 clients
- Official Android app available
- No third-party dependencies — fully self-contained
- Cost: ~$4/month (B1s VM) + public IP
- Trade-off: you manage the VM (patching, strongSwan config)

### Azure VPN Gateway P2S (future option)

Managed Azure service with IKEv2 support. Native OS clients with certificate auth, or Azure VPN Client app for Entra ID auth.

- Managed service — no VM to maintain
- Dual-stack P2S supported (IPv4 + IPv6 client address pools), requires VpnGw1+
- IKEv2 with native clients (cert auth) or OpenVPN with Azure VPN Client (Entra ID auth)
- Official Azure networking pattern (matches landing zone architecture)
- Cost: ~$140/month for VpnGw1 (minimum SKU for IKEv2 + IPv6). Basic SKU (~$27/month) does not support IKEv2, IPv6, or RADIUS.
- Can deallocate gateway when not testing, but recreation takes ~30-45 minutes
- Trade-off: higher cost, but zero server management

### WireGuard on an Azure VM (future option)

Modern VPN protocol on a small VM. Requires WireGuard app on the client (not native to any OS).

- Full IPv6 dual-stack support
- Excellent performance (kernel-level, low overhead)
- Simple config (key pairs, no certificates or EAP)
- No third-party service dependencies
- Cost: ~$4/month (B1s VM) + public IP
- Trade-off: requires app install on client machines (not native), more manual peer configuration, no built-in IP pool management

### Not chosen

- **Tailscale** — managed overlay network built on WireGuard. Very easy setup, but metadata goes through Tailscale's coordination servers, which conflicts with the "no data to third parties" goal.
- **Libreswan** — similar to strongSwan but lacks EAP support, less suited to road-warrior/P2S scenarios, not referenced in Azure docs. Better for site-to-site or RHEL/FIPS environments.
- **OpenVPN** — requires client app install on all platforms, no native OS support. No advantage over strongSwan for this use case.
- **Azure Bastion** — browser-based access to a jumpbox VM, not a routable VPN. Can't route local tools through it to the LLM endpoint.

## Existing solutions

Existing Bicep templates for deploying Azure AI Foundry with network isolation (all MIT licensed):

- **Azure AI Foundry Network Restricted** (Azure Quickstart Templates) — Deploys Azure AI Foundry with private link and egress disabled. Includes VNet, subnets, NSGs, AI Hub, Key Vault, Storage Account, Container Registry, AI Services endpoint, and AI Search, all with private endpoints. Two-step deployment (pre-reqs then main). https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.machinelearningservices/aifoundry-network-restricted

- **Deploy Secure Azure AI Foundry via Bicep** (Azure Samples) — Two variants: without VNet (`bicep/novnet/`) for simpler testing, and with managed virtual network isolation (`bicep/managedvnet/`). Includes "Deploy to Azure" buttons for portal deployment and Bash scripts for deploying and testing a prompt flow against the deployed model. https://github.com/Azure-Samples/azure-ai-studio-secure-bicep

- **Machine Learning End-to-End Secure** (Azure Quickstart Templates) — A more traditional Azure ML workspace with full VNet isolation. Less Foundry-specific, gives more control for running a model on a raw GPU VM rather than through the model catalog. https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.machinelearningservices/machine-learning-end-to-end-secure

