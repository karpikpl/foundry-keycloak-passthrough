// infra/main.bicep — AZD orchestrator for cloud-helper-keycloak
//
// Foundry → MCP OAuth passthrough demo, with **Keycloak** as the
// authorization server (Entra is federated into Keycloak as an upstream OIDC
// IdP). Reuses the same VNet / Foundry / App Service modules as the original
// foundry-entra-passthrough repo; the Keycloak host, its Postgres backend and
// the realm-provisioning step are added on top.
//
// Order of deployment:
//   1. VNet (with the existing acaSubnet, delegated Microsoft.app/environments)
//   2. Log Analytics + App Insights
//   3. Project managed identity
//   4. AI Foundry account + dependencies + project
//   5. Postgres flexible server (Keycloak backend)
//   6. Keycloak Container App (ACA env reuses acaSubnet)
//   7. App Service hosting the MCP server (validates Keycloak JWTs)
//   8. Entra app registration (upstream OIDC IdP for Keycloak)
//   9. Foundry private endpoint + Foundry MCP connection (postprovision)

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

@description('Keycloak realm name created by postprovision.')
param keycloakRealm string = 'mcp-demo'

@description('Initial Keycloak admin username.')
param keycloakAdminUsername string = 'admin'

@secure()
@description('Initial Keycloak admin password — supply via `azd env set KEYCLOAK_ADMIN_PASSWORD <value>` (required).')
param keycloakAdminPassword string

@secure()
@description('Postgres admin password — supply via `azd env set POSTGRES_ADMIN_PASSWORD <value>` (required).')
param postgresAdminPassword string

// ── Derived ───────────────────────────────────────────────────────────────────
var tenantId = subscription().tenantId
var resourceToken = toLower(uniqueString(resourceGroup().id, location))

var webAppName = 'cloud-helper-keycloak-${resourceToken}'

var tags = {
  project: 'cloud-helper-keycloak'
  environment: environmentName
  managedBy: 'azd'
  'hidden-title': 'Keycloak MCP OAuth Demo'
}

// ── Entra app registration (upstream IdP for Keycloak) ───────────────────────
module appRegs './modules/appRegistrations.bicep' = {
  name: 'appRegistrations-${environmentName}'
  params: {
    environmentName: environmentName
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

// Need the workspace customerId + sharedKey for the ACA environment.
// (Both come from the loganalytics module so we don't `existing`-reference a
// resource whose name is only known at runtime.)

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
    aiServicesName: ''
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
    project_description: 'Keycloak MCP OAuth demo project'
    display_name: 'Keycloak MCP OAuth Project'
    projectId: 1
    aiDependencies: aiDependencies.outputs.AI_DEPENDECIES
    existingAiResourceId: null
    managedIdentityResourceId: projectIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
  }
}

// ── Postgres flexible server (Keycloak backend) ──────────────────────────────
module postgres './modules/data/postgres.bicep' = {
  name: 'postgres-${resourceToken}'
  params: {
    name: 'pg-keycloak-${resourceToken}'
    location: location
    tags: tags
    administratorPassword: postgresAdminPassword
  }
}

// ── Keycloak on Azure Container Apps ─────────────────────────────────────────
module keycloak './modules/apps/keycloak-aca.bicep' = {
  name: 'keycloak-${resourceToken}'
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    acaSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.acaSubnet.resourceId
    logAnalyticsCustomerId: logAnalytics.outputs.LOG_ANALYTICS_CUSTOMER_ID
    logAnalyticsSharedKey: logAnalytics.outputs.LOG_ANALYTICS_PRIMARY_SHARED_KEY
    dbJdbcUrl: postgres.outputs.jdbcUrl
    dbUsername: postgres.outputs.administratorLogin
    dbPassword: postgresAdminPassword
    bootstrapAdminUsername: keycloakAdminUsername
    bootstrapAdminPassword: keycloakAdminPassword
  }
}

// ── App Service hosting the MCP server ───────────────────────────────────────
module appSvc './modules/appService.bicep' = {
  name: 'appService-${environmentName}'
  params: {
    location: location
    tenantId: tenantId
    webAppName: webAppName
    resourceToken: resourceToken
    existingPlanName: existingPlanName
    // The Bicep module wires CLIENT_ID/AUDIENCE/TENANT_ID/RESOURCE_HOST into
    // the App Service app settings. Those names are still meaningful in the
    // Keycloak variant — the postdeploy hook overlays additional settings
    // (KEYCLOAK_BASE_URL, KEYCLOAK_REALM) once Keycloak's FQDN is known.
    audience: 'mcp-server'
    appId: 'mcp-server'
    tags: tags
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
  }
}

// ── Private endpoint + DNS + Foundry MCP connection scaffolding ──────────────
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
        audience: 'mcp-server'
        clientId: 'mcp-server'
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
output APP_SLOT_HOSTNAME string = appSvc.outputs.webAppHostname
output ENTRA_APP_CLIENT_ID string = appRegs.outputs.clientId
output ENTRA_APP_DISPLAY_NAME string = appRegs.outputs.appDisplayName
output KEYCLOAK_FQDN string = keycloak.outputs.fqdn
output KEYCLOAK_BASE_URL string = keycloak.outputs.baseUrl
output KEYCLOAK_REALM string = keycloakRealm
output KEYCLOAK_ADMIN_USERNAME string = keycloakAdminUsername
output KEYCLOAK_CONTAINER_APP_NAME string = keycloak.outputs.containerAppName
output POSTGRES_SERVER_NAME string = postgres.outputs.serverName
output POSTGRES_FQDN string = postgres.outputs.fqdn
output POSTGRES_DATABASE_NAME string = postgres.outputs.databaseName
output POSTGRES_ADMIN_LOGIN string = postgres.outputs.administratorLogin
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output FOUNDRY_ENDPOINT string = foundry.outputs.FOUNDRY_ENDPOINT
output FOUNDRY_PROJECT_NAME string = aiProject.outputs.FOUNDRY_PROJECT_NAME
output FOUNDRY_PROJECT_CONNECTION_STRING string = aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
output AZURE_OPENAI_CHAT_DEPLOYMENT_NAME string = chatDeploymentName
output VNET_RESOURCE_ID string = vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
@description('MCP connection JSON payloads sent to ARM — inspect to troubleshoot Foundry connection failures.')
output MCP_CONNECTION_PAYLOADS array = mcpApis.outputs.mcpConnectionPayloads

