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

https://www.bentoml.com/blog/navigating-the-world-of-open-source-large-language-models

- Cheap low cost model as proof of concept

- How do local tools connect to models? Is there an open protocol? Which tools support it?

- Need a separate example test container, that has a tool, and can be used to validate connectivity.

## General concepts

- Support IPv6
- Use a unique prefix/token, i.e. so can run in different Azure subscriptions without naming conflicts (i.e. use for global namespaces)
  - An example of this is in https://github.com/sgryphon/iot-demo-build (based on subscription ID prefix; I've also seen some Microsoft scripts with 'unique' (hash) calcs)
    - Note that the iot demo scripts also allocate network ranges based on prefixes, e.g. so you can have both a prod and test range.
    - Follow official MS well architected naming rules (note that many examples, including from MS, do not follow the rules)
- All infrastructure is scripted
  - I like migrations, because I don't trust desired state
  - I've learned the lesson too many times with databases
  - There are simply changes where A->B->C can not be determine from only A,C (mathematical reality).
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



