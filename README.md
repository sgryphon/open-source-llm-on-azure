# open-source-llm-on-azure
Blueprints for deploying open source LLMs on Azure.


## Goal

Goal is to run an open source LLM on Azure, in a private environment, with a local AI tool connecting to the open source LLM. i.e. can get code (or agents) without sending data to any third party or outside our Azure tennant.

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

## Existing solutions

Existing Bicep templates for deploying Azure AI Foundry with network isolation (all MIT licensed):

- **Azure AI Foundry Network Restricted** (Azure Quickstart Templates) — Deploys Azure AI Foundry with private link and egress disabled. Includes VNet, subnets, NSGs, AI Hub, Key Vault, Storage Account, Container Registry, AI Services endpoint, and AI Search, all with private endpoints. Two-step deployment (pre-reqs then main). https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.machinelearningservices/aifoundry-network-restricted

- **Deploy Secure Azure AI Foundry via Bicep** (Azure Samples) — Two variants: without VNet (`bicep/novnet/`) for simpler testing, and with managed virtual network isolation (`bicep/managedvnet/`). Includes "Deploy to Azure" buttons for portal deployment and Bash scripts for deploying and testing a prompt flow against the deployed model. https://github.com/Azure-Samples/azure-ai-studio-secure-bicep

- **Machine Learning End-to-End Secure** (Azure Quickstart Templates) — A more traditional Azure ML workspace with full VNet isolation. Less Foundry-specific, gives more control for running a model on a raw GPU VM rather than through the model catalog. https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.machinelearningservices/machine-learning-end-to-end-secure

