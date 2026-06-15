// infra/main.bicep — AZD orchestrator for cloud-helper-fastmcp
//
// Deploys:
//   1. VNet with subnets (agent, PE, appGw, APIM…)
//   2. Log Analytics + App Insights
//   3. Managed Identity for the AI Project
//   4. AI Foundry account (Standard, VNet-injected)
//   5. AI dependency resources: Search, Storage, Cosmos DB (with PEs + DNS)
//   6. AI Project with capability host (Agents Standard mode)
//   7. App Service (AVM Linux B1) — code host for the MCP server
//   8. Entra app registration (resource-server app, reused across envs)
//   9. Private endpoint + DNS zone for the App Service + Foundry RemoteTool
//      connection with Entra Identity Passthrough

targetScope = 'resourceGroup'

@description('Environment name — used to suffix and tag resources. Set via: azd env new <name>')
param environmentName string

@description('Azure region for App Service resources. Defaults to resource group location.')
param location string = resourceGroup().location

@description('Name of an existing App Service Plan to reuse. Leave empty to create a new B1 plan.')
param existingPlanName string = ''

@description('Public network access on the AI Foundry account.')
@allowed(['Enabled', 'Disabled'])
param foundryPublicNetworkAccess string = 'Enabled'

@description('Chat model deployment name.')
param chatDeploymentName string = 'gpt-4o'

@description('Chat model version.')
param chatModelVersion string = '2024-11-20'

@description('Chat deployment capacity (tokens per minute × 1 000).')
param chatDeploymentCapacity int = 20

// ── Derived ───────────────────────────────────────────────────────────────────
var tenantId = subscription().tenantId
var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// App Service name derived from resource token — globally unique per environment.
var webAppName = 'cloud-helper-mcp-${resourceToken}'

var tags = {
  project: 'cloud-helper-fastmcp'
  environment: environmentName
  managedBy: 'azd'
  'hidden-title': 'MCP OAuth Demo'
}

// ── App Registrations (Entra, via MS Graph Bicep extension) ──────────────────
module appRegs './modules/appRegistrations.bicep' = {
  name: 'appRegistrations-${environmentName}'
  params: {
    environmentName: environmentName
    webAppName: webAppName
  }
}

// ── Virtual Network ───────────────────────────────────────────────────────────
module vnet './modules/networking/vnet.bicep' = {
  name: 'vnet-${resourceToken}'
  params: {
    tags: tags
    location: location
    vnetName: 'vnet-${resourceToken}'
  }
}

// ── Log Analytics + Application Insights ─────────────────────────────────────
module logAnalytics './modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics-${resourceToken}'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-${resourceToken}'
    newApplicationInsightsName: 'appi-${resourceToken}'
  }
}

// ── Managed Identity for the AI Project ──────────────────────────────────────
module projectIdentity './modules/iam/identity.bicep' = {
  name: 'project-identity-${resourceToken}'
  params: {
    tags: tags
    location: location
    identityName: 'id-project-${resourceToken}'
  }
}

// ── AI Foundry account ────────────────────────────────────────────────────────
module foundry './modules/ai/ai-foundry.bicep' = {
  name: 'foundry-${resourceToken}'
  params: {
    tags: tags
    location: location
    name: 'aif-${resourceToken}'
    publicNetworkAccess: foundryPublicNetworkAccess
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
    deployments: [
      {
        name: chatDeploymentName
        properties: {
          model: {
            format: 'OpenAI'
            name: chatDeploymentName
            version: chatModelVersion
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: chatDeploymentCapacity
        }
      }
    ]
  }
}

// ── AI dependency resources: Search + Storage + Cosmos (with PEs + DNS) ──────
module aiDependencies './modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-${resourceToken}'
  params: {
    tags: tags
    location: location
    resourceToken: resourceToken
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    aiServicesName: ''                  // Foundry PE created separately if needed
    aiAccountNameResourceGroupName: ''
  }
}

// ── AI Project with capability host ──────────────────────────────────────────
module aiProject './modules/ai/ai-project-with-caphost.bicep' = {
  name: 'ai-project-${resourceToken}'
  params: {
    tags: tags
    location: location
    foundryName: foundry.outputs.FOUNDRY_NAME
    project_name: 'proj-${resourceToken}'
    project_description: 'MCP OAuth demo project'
    display_name: 'MCP OAuth Project'
    projectId: 1
    aiDependencies: aiDependencies.outputs.AI_DEPENDECIES
    existingAiResourceId: null
    managedIdentityResourceId: projectIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
  }
}

// ── App Service (AVM) ─────────────────────────────────────────────────────────
// PE is created below by apps-private-link so the DNS zone is shared
// with any future APIs added to the same VNet.
module appSvc './modules/appService.bicep' = {
  name: 'appService-${environmentName}'
  params: {
    location: location
    tenantId: tenantId
    webAppName: webAppName
    resourceToken: resourceToken
    existingPlanName: existingPlanName
    audience: appRegs.outputs.audience
    appId: appRegs.outputs.clientId
    tags: tags
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
  }
}

// ── Private endpoint + DNS + Foundry MCP connection ──────────────────────────
// Registers the App Service as a RemoteTool in Foundry with Entra passthrough.
module mcpApis './modules/apps/apps-private-link.bicep' = {
  name: 'mcp-apis-${resourceToken}'
  params: {
    tags: tags
    location: location
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    createMcpConnection: false
    apis: [
      {
        name: webAppName
        resourceId: appSvc.outputs.webAppResourceId
        type: 'sites'
        dnsZoneName: 'privatelink.azurewebsites.net'
        uri: 'https://${appSvc.outputs.webAppHostname}'
        audience: appRegs.outputs.audience
        clientId: appRegs.outputs.clientId
      }
    ]
  }
  dependsOn: [aiProject]
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenantId
output WEB_APP_NAME string = appSvc.outputs.webAppName
output WEB_APP_HOSTNAME string = appSvc.outputs.webAppHostname
output ENTRA_APP_CLIENT_ID string = appRegs.outputs.clientId
output ENTRA_APP_AUDIENCE string = appRegs.outputs.audience
output ENTRA_APP_SCOPE string = appRegs.outputs.scope
output APP_SLOT_HOSTNAME string = appSvc.outputs.webAppHostname
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output FOUNDRY_ENDPOINT string = foundry.outputs.FOUNDRY_ENDPOINT
output FOUNDRY_PROJECT_NAME string = aiProject.outputs.FOUNDRY_PROJECT_NAME
output FOUNDRY_PROJECT_CONNECTION_STRING string = aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
output AZURE_OPENAI_CHAT_DEPLOYMENT_NAME string = chatDeploymentName
output VNET_RESOURCE_ID string = vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
@description('MCP connection JSON payloads sent to ARM — inspect to troubleshoot Foundry connection failures.')
output MCP_CONNECTION_PAYLOADS array = mcpApis.outputs.mcpConnectionPayloads
