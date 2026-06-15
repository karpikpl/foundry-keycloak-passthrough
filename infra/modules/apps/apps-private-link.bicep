// Creates a private DNS zone + private endpoint for the App Service MCP server,
// then registers it as a RemoteTool connection in AI Foundry using
// Entra Identity Passthrough (the caller's Entra token is forwarded on each call).

param location string
param tags object = {}
param vnetResourceId string
param peSubnetResourceId string
param aiFoundryName string

@description('Set to true to create the Foundry MCP connection via Bicep. Default is false — connection is created via az rest in the postprovision hook instead, which supports the full OAuth2 property set.')
param createMcpConnection bool = false

@export()
type apiType = {
  name: string
  resourceId: string
  @description('Use "sites" for App Service, "managedEnvironments" for ACA')
  type: 'sites' | 'managedEnvironments'
  @description('e.g. privatelink.azurewebsites.net')
  dnsZoneName: string
  @description('Base URL of the MCP server — used as the Foundry connection target')
  uri: string
  @description('Audience (api://...) of the app registration for Entra passthrough')
  audience: string
  @description('Client ID of the app registration')
  clientId: string
}

param apis apiType[] = []

// ── Private DNS zone for App Service ─────────────────────────────────────────
module dnsSites 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'dns-sites'
  params: {
    tags: tags
    name: 'privatelink.azurewebsites.net'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: vnetResourceId
      }
    ]
  }
}

// ── Private endpoints ─────────────────────────────────────────────────────────
module privateEndpoints '../networking/private-endpoint.bicep' = [
  for (api, i) in apis: {
    name: 'pe-${api.name}'
    params: {
      tags: tags
      privateEndpointName: 'pe-${api.name}'
      location: location
      subnetId: peSubnetResourceId
      targetResourceId: api.resourceId
      groupIds: [api.type]
      zoneConfigs: [
        {
          name: api.dnsZoneName
          privateDnsZoneId: dnsSites.outputs.resourceId
        }
      ]
    }
  }
]

// ── Foundry RemoteTool connections — OAuth2 (Entra) ──────────────────────────
// authType 'OAuth2' with clientId triggers the PKCE/delegated auth flow.
// Foundry acquires a token scoped to audience/mcp.access on behalf of the user.
var loginEndpoint = environment().authentication.loginEndpoint
var tenantId = tenant().tenantId

// Build payloads as a variable so the full JSON is surfaced in outputs for
// troubleshooting (run `azd provision` then check the mcpConnectionPayloads output).
var connectionPayloads = [
  for api in apis: {
    name: 'MCP-${api.name}'
    properties: {
      category: 'RemoteTool'
      target: api.uri
      authType: 'OAuth2'
      isSharedToAll: true
      credentials: {
        clientId: api.clientId
        authUrl: '${loginEndpoint}${tenantId}/oauth2/v2.0/authorize'
      }
      metadata: {
        type: 'custom_MCP'
        audience: api.audience
        clientId: api.clientId
        tokenUrl: '${loginEndpoint}${tenantId}/oauth2/v2.0/token'
        refreshUrl: '${loginEndpoint}${tenantId}/oauth2/v2.0/token'
        scopes: '${api.audience}/mcp.access'
      }
    }
  }
]

resource foundry 'Microsoft.CognitiveServices/accounts@2026-01-15-preview' existing = {
  name: aiFoundryName
}

// createMcpConnection=false by default — the postprovision hook creates the connection
// via az rest, which supports the full OAuth2 property set that Bicep types do not expose.
resource mcpConnections 'Microsoft.CognitiveServices/accounts/connections@2026-01-15-preview' = [
  for (payload, i) in (createMcpConnection ? connectionPayloads : []): {
    name: payload.name
    parent: foundry
    properties: payload.properties
  }
]

@description('Full JSON payloads sent to ARM for each MCP connection — use to verify properties before/after deployment.')
output mcpConnectionPayloads array = connectionPayloads
