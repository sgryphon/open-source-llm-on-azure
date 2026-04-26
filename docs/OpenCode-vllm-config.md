# Wiring OpenCode to the self-hosted vLLM endpoint

This is the operator-facing payoff of the `azure-vllm` deployment: point
OpenCode at the public HTTPS endpoint and use Qwen2.5-Coder-7B as a coding
agent. OpenCode talks the OpenAI Chat Completions API, which vLLM serves
natively, so this is a pure configuration step on the operator's workstation.

## Prerequisites

- All of `c-workload/01..06`, then `util/Download-LlmModelToDisk.ps1`, then
  `c-workload/07-Test-LlmEndpoint.ps1` have run cleanly. The smoke test
  passing confirms the endpoint is healthy *and* the cert is trusted by a
  default `Invoke-RestMethod` (i.e. by anything else, including OpenCode).
- The operator can reach the IPv6 FQDN of the vLLM VM. Most home and corp
  networks have IPv6 these days; if your network is IPv4-only, swap the
  hostname for the IPv4 FQDN below — both are on the same cert.

## Fetch the values

```pwsh
# IPv6 FQDN (cert primary; preferred)
$fqdn = (az network public-ip show `
    --resource-group rg-llm-workload-dev-001 `
    --name pip-llm-vllm-dev-australiaeast-001 `
    --query dnsSettings.fqdn -o tsv)

# Bearer token (the same value vllm.service is consuming via /etc/vllm/vllm.env)
$apiKey = (az keyvault secret show `
    --vault-name kv-llm-shared-0xacc5-dev `
    --name vllm-api-key `
    --query value -o tsv)

"https://$fqdn"
$apiKey
```

Substitute your own RG name, PIP name, and Key Vault name (the script
parameters in `c-workload/` follow `rg-llm-workload-<env>-001`,
`pip-llm-vllm-<env>-<region>-001`, `kv-llm-shared-<orgid>-<env>`).

## Edit `~/.config/opencode/opencode.json`

Add a `provider` block pointing at the vLLM endpoint and a `model` entry that
references it. The `name` you pick is purely for OpenCode's UI; the
`models[].name` must match the served model id (`qwen2.5-coder-7b` by
default), which is what vLLM advertises at `/v1/models`.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "vllm-azure": {
      "name": "vLLM on Azure (Qwen2.5-Coder-7B)",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://llm-0xacc5-dev.australiaeast.cloudapp.azure.com/v1",
        "apiKey": "REPLACE_WITH_VLLM_API_KEY"
      },
      "models": {
        "qwen2.5-coder-7b": {
          "name": "Qwen2.5-Coder-7B-Instruct (AWQ)",
          "tools": true
        }
      }
    }
  }
}
```

Replace the `baseURL` host and the `apiKey` value with the two strings you
captured above. Note the trailing `/v1` — OpenCode appends `/chat/completions`
to whatever you put here.

## Confirm

Restart OpenCode and select the new model. A short test prompt
("write a fizzbuzz in Rust") will:

1. POST `/v1/chat/completions` to your VM with `Authorization: Bearer <key>`.
2. Round-trip the response.

If OpenCode gets a 401, the API key is stale (was the secret rotated?).
If OpenCode gets a TLS error, the cert is staging — re-issue with production
ACME (re-run `06-Deploy-LlmVm.ps1` without `-AcmeStaging`, after deleting the
existing `/etc/letsencrypt/live/vllm-cert/` directory if needed).

## Rotating the key

After you run `c-workload/Rotate-LlmApiKey.ps1`, the OLD key in your
`opencode.json` will start returning 401. Capture the new key it prints to
the terminal and update the `apiKey` field above. There is no other state to
sync.
