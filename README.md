# Open Source LLM's in your Azure tennant

Blueprints for deploying open source LLMs on Azure.

## Goal

Connect your local AI tools to an open source LLM, run in a private environment on Azure, without sending data or code ourside your Azure tenant or to any third party.

## How to run

1. You will need an Azure subscription. Scripts are written assuming you have full access.
2. Log in
3. Run the scripts in each section, in numerical order.

If you have a more locked down environment, you may need to get central IT to provision out the `infrastructure` (resource groups and network routing) that you need.

Similarly, if you already have the relevant components from `shared` then you don't need to deploy them.

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
