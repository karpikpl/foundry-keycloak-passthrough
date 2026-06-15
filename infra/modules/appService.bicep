// infra/modules/appService.bicep
// Uses Azure Verified Modules (AVM) for the App Service plan and site,
// following the pattern from function-app-with-plan.bicep in the sample.
// Private endpoint wiring (DNS zone + PE) is handled by apps/apps-private-link.bicep.

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string

@description('Entra tenant ID.')
param tenantId string

@description('App Service name — derived from resource token in main.bicep.')
param webAppName string

@description('Resource token for naming the App Service Plan uniquely.')
param resourceToken string

@description('Name of an existing App Service Plan to reuse. Empty = create a new B1 Linux plan.')
param existingPlanName string = ''

@description('Client ID of the app registration.')
param appId string

@description('Full audience URI (api://...) of the app.')
param audience string

@description('Tags to apply to all resources.')
param tags object = {}

@description('Resource ID of the PE subnet. When set, a private endpoint is created for the site.')
param peSubnetResourceId string = ''

// ── App Service Plan ──────────────────────────────────────────────────────────

var planName = 'cloud-helper-mcp-plan-${resourceToken}'

resource existingPlan 'Microsoft.Web/serverfarms@2023-12-01' existing = if (!empty(existingPlanName)) {
  name: existingPlanName
}

resource newPlan 'Microsoft.Web/serverfarms@2023-12-01' = if (empty(existingPlanName)) {
  name: planName
  location: location
  tags: tags
  sku: { name: 'B1' }
  kind: 'linux'
  properties: { reserved: true }
}

var planId = empty(existingPlanName) ? newPlan.id : existingPlan.id

// ── App Service site (AVM) ────────────────────────────────────────────────────
// br/public:avm/res/web/site:0.22.0
module webApp 'br/public:avm/res/web/site:0.22.0' = {
  name: 'app-site-${webAppName}'
  params: {
    name: webAppName
    location: location
    tags: union(tags, { 'azd-service-name': 'server' })
    kind: 'app,linux'
    serverFarmResourceId: planId
    httpsOnly: true
    // Keep public network access on so AZD/Kudu can zip-deploy.
    // The private endpoint gives Foundry a private path; it does not need
    // the public endpoint closed for security in this setup.
    publicNetworkAccess: 'Enabled'
    managedIdentities: { systemAssigned: true }
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      appCommandLine: 'bash startup.sh'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
    }
    configs: [
      {
        name: 'appsettings'
        properties: {
          CLIENT_ID: appId
          AUDIENCE: audience
          RESOURCE_APP_ID: appId
          RESOURCE_HOST: '${webAppName}.azurewebsites.net'
          TENANT_ID: tenantId
          AZURE_TENANT_ID: tenantId
          PORT: '8000'
          SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
          WEBSITES_PORT: '8000'
          PYTHON_ENABLE_GUNICORN_MULTIWORKERS: 'true'
        }
      }
    ]
    privateEndpoints: !empty(peSubnetResourceId)
      ? [
          {
            subnetResourceId: peSubnetResourceId
            service: 'sites'
          }
        ]
      : []
  }
}

output webAppName string = webApp.outputs.name
output webAppHostname string = webApp.outputs.defaultHostname
output webAppResourceId string = webApp.outputs.resourceId
output planId string = planId
output webAppPrincipalId string = webApp.outputs.systemAssignedMIPrincipalId
