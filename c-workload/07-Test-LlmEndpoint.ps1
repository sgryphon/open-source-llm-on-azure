#!/usr/bin/env pwsh

<# .SYNOPSIS
  Smoke-test the deployed vLLM endpoint over HTTPS with a real bearer token.

.DESCRIPTION
  Two assertions:

    1. `GET https://<fqdn>/v1/models` returns 200 and the response
       `data[].id` array contains the served model name (default
       `qwen2.5-coder-7b`).
    2. `POST https://<fqdn>/v1/chat/completions` with one tool definition
       (`get_weather(location: string)`) and a London-weather user message
       returns 200, and `choices[0].message.tool_calls[0].function.name`
       equals `get_weather`.

  These are the only two capabilities OpenCode actually exercises against
  this server: model discovery and tool-calling. Anything beyond is
  implementation detail.

  By default the script tests the IPv6 FQDN; pass `-TestIpv4` to test the
  IPv4 FQDN instead (useful from IPv4-only networks).

  TLS: real Let's Encrypt cert verification is on by default. With
  `-AcmeStaging` the script falls back to `-SkipCertificateCheck` and
  emits a warning -- staging certs are not trusted by `Invoke-RestMethod`
  out of the box.

.NOTES
  Prerequisite: `util/Download-LlmModelToDisk.ps1` has been run at least
  once and `vllm.service` is `active` on the VM. If the model has not
  been loaded the GET to `/v1/models` will fail at the TCP level; the
  script emits a hint pointing at the model-download script.

.EXAMPLE

  az login
  az account set --subscription <subscription id>
  $VerbosePreference = 'Continue'
  ./c-workload/07-Test-LlmEndpoint.ps1
#>
[CmdletBinding()]
param (
    ## Test the IPv4 FQDN instead of the IPv6 FQDN.
    [switch]$TestIpv4 = ($ENV:DEPLOY_TEST_IPV4 -eq 'true' -or $ENV:DEPLOY_TEST_IPV4 -eq '1'),
    ## Cert was issued by Let's Encrypt staging; skip cert verification.
    [switch]$AcmeStaging = ($ENV:DEPLOY_ACME_STAGING -eq 'true' -or $ENV:DEPLOY_ACME_STAGING -eq '1'),
    ## Served model name (must match what the VM's vllm.service serves).
    [string]$ServedModelName = $ENV:DEPLOY_SERVED_MODEL_NAME ?? 'qwen2.5-coder-7b',
    ## Purpose prefix.
    [string]$Purpose = $ENV:DEPLOY_PURPOSE ?? 'LLM',
    ## Workload prefix.
    [string]$Workload = $ENV:DEPLOY_WORKLOAD ?? 'workload',
    ## Deployment environment.
    [string]$Environment = $ENV:DEPLOY_ENVIRONMENT ?? 'Dev',
    ## Identifier for the organisation (or subscription) to make global names unique.
    [string]$OrgId = $ENV:DEPLOY_ORGID ?? "0x$((az account show --query id --output tsv).Substring(0,4))",
    ## Instance number uniquifier.
    [string]$Instance = $ENV:DEPLOY_INSTANCE ?? '001'
)

$ErrorActionPreference = 'Stop'

$rgName     = "rg-$Purpose-$Workload-$Environment-$Instance".ToLowerInvariant()
$rg         = az group show --name $rgName 2>$null | ConvertFrom-Json
if (-not $rg) { throw "Workload resource group '$rgName' not found." }
$location   = $rg.location
$locationLower = $location.ToLowerInvariant()

$pipName = if ($TestIpv4) {
    "pipv4-$Purpose-vllm-$Environment-$locationLower-$Instance".ToLowerInvariant()
} else {
    "pip-$Purpose-vllm-$Environment-$locationLower-$Instance".ToLowerInvariant()
}
$pip = az network public-ip show --name $pipName --resource-group $rgName 2>$null | ConvertFrom-Json
if (-not $pip) { throw "Public IP '$pipName' not found." }
$fqdn = $pip.dnsSettings.fqdn
if (-not $fqdn) { throw "Public IP '$pipName' is missing a DNS FQDN." }
Write-Verbose "Testing endpoint: https://$fqdn  (TestIpv4=$TestIpv4)"

# Fetch the API key from the shared Key Vault.
$kvName = "kv-$Purpose-shared-$OrgId-$Environment".ToLowerInvariant()
$apiKeySecretName = 'vllm-api-key'
$apiKey = az keyvault secret show --vault-name $kvName --name $apiKeySecretName --query value -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw "Could not read secret '$apiKeySecretName' from Key Vault '$kvName'."
}
$headers = @{ Authorization = "Bearer $apiKey" }

# TLS: skip verification only for ACME staging.
$invokeArgs = @{ Headers = $headers }
if ($AcmeStaging) {
    Write-Warning "ACME staging mode: using -SkipCertificateCheck. The cert is NOT trusted by browsers/OpenCode."
    $invokeArgs['SkipCertificateCheck'] = $true
}

# ---------------------------------------------------------------------------
# Test 1: GET /v1/models
# ---------------------------------------------------------------------------

Write-Verbose "Test 1/2: GET https://$fqdn/v1/models"
$modelsUri = "https://$fqdn/v1/models"
try {
    $models = Invoke-RestMethod -Method Get -Uri $modelsUri @invokeArgs -TimeoutSec 30
} catch {
    Write-Error @"
GET $modelsUri failed: $($_.Exception.Message)

Most likely causes:
  * vllm.service is not active yet -> run util/Download-LlmModelToDisk.ps1
    to populate the model files; the service starts automatically when
    the model is on disk.
  * NSG/firewall blocking the test client.
  * Cert is staging (re-run with -AcmeStaging).
"@
    exit 1
}

$modelIds = @($models.data | ForEach-Object { $_.id })
Write-Verbose "  /v1/models returned: $($modelIds -join ', ')"
if ($modelIds -notcontains $ServedModelName) {
    Write-Error "FAIL: '$ServedModelName' not present in /v1/models response. Got: $($modelIds -join ', ')"
    exit 1
}
Write-Verbose "  PASS: '$ServedModelName' is present."

# ---------------------------------------------------------------------------
# Test 2: POST /v1/chat/completions with a tool definition.
# ---------------------------------------------------------------------------

Write-Verbose "Test 2/2: POST https://$fqdn/v1/chat/completions (tool-calling: get_weather)"
$chatUri = "https://$fqdn/v1/chat/completions"
$chatBody = @{
    model    = $ServedModelName
    messages = @(
        @{ role = 'user'; content = "what's the weather in London?" }
    )
    tools = @(
        @{
            type     = 'function'
            function = @{
                name        = 'get_weather'
                description = 'Get the current weather for a given city.'
                parameters  = @{
                    type       = 'object'
                    properties = @{
                        location = @{
                            type        = 'string'
                            description = 'City name, e.g. "London"'
                        }
                    }
                    required = @('location')
                }
            }
        }
    )
    tool_choice = 'auto'
} | ConvertTo-Json -Depth 10

try {
    $chat = Invoke-RestMethod -Method Post -Uri $chatUri -Body $chatBody -ContentType 'application/json' @invokeArgs -TimeoutSec 60
} catch {
    Write-Error "POST $chatUri failed: $($_.Exception.Message)"
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        Write-Error "Response body: $($_.ErrorDetails.Message)"
    }
    exit 1
}

$toolCalls = @($chat.choices[0].message.tool_calls)
if ($toolCalls.Count -eq 0) {
    Write-Error @"
FAIL: chat completion did not include tool_calls.
Got message: $($chat.choices[0].message | ConvertTo-Json -Depth 5 -Compress)
"@
    exit 1
}
$firstName = $toolCalls[0].function.name
Write-Verbose "  tool_calls[0].function.name = '$firstName'"
if ($firstName -ne 'get_weather') {
    Write-Error "FAIL: expected tool_calls[0].function.name='get_weather', got '$firstName'."
    exit 1
}
Write-Verbose "  PASS: model invoked the get_weather tool."

Write-Verbose ""
Write-Verbose "Both tests passed against https://$fqdn."
exit 0
