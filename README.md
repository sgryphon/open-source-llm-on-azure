# Open Source LLM's in your Azure tennant

Blueprints for deploying open source LLMs on Azure.

## Goal

Connect your local AI tools to an open source LLM, run in a private environment on Azure, without sending data or code ourside your Azure tenant or to any third party.

## How to run

Scripts are writting in PowerShell, and use the Azure CLI to configure resources.

The development container includes the necessary tools.

Before running scripts, enable verbose output to see processing details:

```powershell
$VerbosePreference = 'Continue'
```

1. You will need an Azure subscription. Scripts are written assuming you have full access.
2. Log in using the Azure CLI (`az login`)
3. Run the `infrastructure` scripts, to create resource groups and network routing. If you have a more locked down environment, you may need to get central IT to provision out what you need.
4. Run the `shared` scripts, in order, to create shared landing zone components. If your enviornment already has shared components some of these may not be needed.

- You need to set the VPN user password, e.g. `$env:DEPLOY_VPN_USER_PASSWORD = 'P@ssword01'`

5. Run the `workload` scripts to deploy the vLLM server.
6. Run the `util/Import-LlmModel.ps` script to download a model to the server.

## Infrastructure: Resource groups and network routing

The `infrastructure` scripts create the following resource groups and networks. In a controlled environment these would be provisioned by Central IT.

| Resource Group          | Purpose                                                         |
| ----------------------- | --------------------------------------------------------------- |
| rg-llm-core-001         | Contains shared services.                                       |
| rg-llm-workload-dev-001 | For the LLM workload. May need to be provisioned by central IT. |

The scripts also use an `fdxx:xxxx:xxxx::/48` ULA range and `10.xx.0.0/16` IPv4 range for networking. The 10-byte ULA global prefix is deterined by a hash of the subscription, so that it is deterministic but varies by subscription.

The following address ranges are allocated to each virtual network (vnet).

| Vnet | IPv6 range | IPv4 range | Purpose |
| vnet-llm-hub-australiaeast-001 | `--:100::/56` | `--.16.0/20` | Central network. Also used for gateway and shared services. |
| vnet-llm-workload-dev-australiaeast-001 | `--:200::/56` | `--.32.0/20` | Central network. Also used for gateway and shared services. |
| VPN Clients | `--:300::/56` | `--.48.0/20` | Reserved range for VPN clients. |

Because IPv4 ranges are restricted, this demo address management uses 4 bits for the vnet and 4 bits for subnets (allowing a /24 subnet).

Two-way peering is configured between the workload vnet and the hub vnet. In a controlled environment the workload vnet may need to be provisioned by Central IT, with appropriate address allocation and routing.

## Shared services

A central IT function may allocate these resources, or they may be dedicated resources for the workload, although they are not part of the workload itself.

| Component     | Details                   | Purpose                                                                                       |
| ------------- | ------------------------- | --------------------------------------------------------------------------------------------- |
| Azure Monitor | log-llm-shared-dev        | Used for monitoring.                                                                          |
| App Insights  | appi-llm-shared-dev       | Used for application monitoring.                                                              |
| KeyVault      | kv-llm-shared-<orgId>-dev | Used for secure storage of secrets and certificates, rather than storing locally on machines. |

### VPN Gateway (StrongSwan)

Road warrior VPN gateway, to demonstrate use of a second layer of security.

DNS host names:

- "vpn-<OrgId>-dev.australiaeast.cloudapp.azure.com"
- "vpn-<OrgId>-dev-ipv4.australiaeast.cloudapp.azure.com"

The following subnet ranges are allocated:

| Vnet                                   | IPv6 range     | IPv4 range   | Purpose                     |
| -------------------------------------- | -------------- | ------------ | --------------------------- |
| snet-llm-gateway-dev-australiaeast-001 | `--:0100::/64` | `--.16.0/24` | VPN gateway subnet.         |
| VPN Clients                            | `--:300::/64`  | `--.48.0/24` | Subnet for VPN client pool. |

The following Azure resources are created (if they do not already exist).

| Component              | Details                               | Purpose                                                                 |
| ---------------------- | ------------------------------------- | ----------------------------------------------------------------------- |
| Network Security Group | nsg-llm-gateway-dev-001               | Security group for gateway subnet.                                      |
| Managed Identity       | id-vmstrongdev001                     | Identity for the VPN gateway server.                                    |
| Public IP              | pip-vmstrongdev001-australiaeast-01   | Public IPv6.                                                            |
| Public IP              | pipv4-vmstrongdev001-australiaeast-01 | Public IPv4.                                                            |
| Network Interface      | nic-vmstrongdev001-01                 | Separate NIC, so that public IP can be retained if server is recreated. |
| Virtual Machine        | vmstrongdev001                        | StrongSwan virtual machine.                                             |
| Disk                   | osdiskvmstrongdev001                  | OS disk for the VM.                                                     |

VPN address pools:

- IPv6 allocates addresses from the range `--:300::1000` to `--:300::1fff`.
- IPv4 allocates addresses from the range `--.48.128` to `--.48.255`.

Default machine size is 'Standard_D2s_v6'.

Required secrets and certificates are stored in the shared Key Vault.

The virtual machine is configured to shut down automatically (based on Brisbane, Australia time), to save costs.

## Workload

DNS host names:

- "llm-<OrgId>-dev-001.australiaeast.cloudapp.azure.com"
- "llm-<OrgId>-dev-001-ipv4.australiaeast.cloudapp.azure.com"

The following subnet ranges are allocated:

| Vnet                                    | IPv6 range     | IPv4 range   | Purpose          |
| --------------------------------------- | -------------- | ------------ | ---------------- |
| snet-llm-workload-dev-australiaeast-001 | `--:0200::/64` | `--.32.0/24` | Workload subnet. |

The following Azure resources are created (if they do not already exist).

Already existing resources are reused, for example if you delete the virtual machine then
the exist model disk and network interface (for IP addresses) will be retained.

| Component              | Details                             | Purpose                                                                    |
| ---------------------- | ----------------------------------- | -------------------------------------------------------------------------- |
| Network Security Group | nsg-llm-workload-dev-001            | Security group for gateway subnet.                                         |
| Managed Identity       | id-vmvllmdev001                     | Identity for the VPN gateway server, with permission to shared Key Vault.  |
| Disk                   | diskmodeldev001                     | Data disk for model download; can detach and persist if server recreated.  |
| Public IP              | pip-vmvllmdev001-australiaeast-01   | Public IPv6; persists across server rebuild.                               |
| Public IP              | pipv4-vmvllmdev001-australiaeast-01 | Public IPv4; persists across server rebuild.                               |
| Network Interface      | nic-vmvllmdev001-01                 | Separate NIC, so that IP addresses can be retained if server is recreated. |
| Virtual Machine        | vmvllmdev001                        | vLLM virtual machine.                                                      |
| Disk                   | osdiskvmvllmdev001                  | OS disk for the VM.                                                        |

Default machine size is 'Standard_NV6ads_A10_v5'. CPU quota and SKU availability are checked for the region.

Required secrets and certificates are stored in the shared Key Vault.

The virtual machine is configured to shut down automatically (based on Brisbane, Australia time), to save costs.

## Troubleshooting

### Cloud init debug

Connect (SSH) to the server:

```sh
ssh azureuser@llm-0x419d-dev-001-ipv4.australiaeast.cloudapp.azure.com
```

Check the cloud init logs:

```sh
more /var/log/cloud-init-output.log
```

Also see: https://docs.microsoft.com/en-us/azure/virtual-machines/linux/cloud-init-troubleshooting

### Configure SSH

SSH is configured as part of server creation.

However if you want to change to a different key you can manually configure, by generating:

```pwsh
ssh-keygen -t rsa -b 4096
```

Then uploading the public key to the server:

```pwsh
az vm user update `
  --username azureuser `
  --ssh-key-value ~/.ssh/id_rsa.pub `
  --resource-group rg-llm-workload-dev-001 `
  --name vmvllmdev001
```

## Notes

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
