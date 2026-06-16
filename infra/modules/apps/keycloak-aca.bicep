// infra/modules/apps/keycloak-aca.bicep
// Keycloak running in Azure Container Apps. Public HTTPS ingress, single
// replica, backed by an external Postgres flexible server passed in via params.
//
// VNet-injected into the existing acaSubnet from networking/vnet.bicep
// (the subnet must already have Microsoft.app/environments delegation).

@description('Azure region.')
param location string

@description('Tags applied to every resource.')
param tags object = {}

@description('Suffix appended to resource names for uniqueness.')
param resourceToken string

@description('Resource ID of the ACA-delegated subnet from the shared VNet.')
param acaSubnetResourceId string

@description('Log Analytics workspace ID for ACA env diagnostics.')
param logAnalyticsCustomerId string
@secure()
@description('Log Analytics primary shared key.')
param logAnalyticsSharedKey string

@description('Keycloak container image — pin a stable tag.')
param keycloakImage string = 'quay.io/keycloak/keycloak:26.0'

@description('Postgres JDBC URL (jdbc:postgresql://...).')
param dbJdbcUrl string

@description('Postgres username.')
param dbUsername string

@secure()
@description('Postgres password.')
param dbPassword string

@description('Initial Keycloak bootstrap admin username.')
param bootstrapAdminUsername string = 'admin'

@secure()
@description('Initial Keycloak bootstrap admin password.')
param bootstrapAdminPassword string

var envName = 'cae-keycloak-${resourceToken}'
var appName = 'keycloak-${resourceToken}'

resource env 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  name: envName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
    vnetConfiguration: {
      internal: false
      infrastructureSubnetId: acaSubnetResourceId
    }
    zoneRedundant: false
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource app 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: appName
  location: location
  tags: tags
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      secrets: [
        { name: 'db-password', value: dbPassword }
        { name: 'admin-password', value: bootstrapAdminPassword }
      ]
    }
    template: {
      containers: [
        {
          name: 'keycloak'
          image: keycloakImage
          // start (production mode) with proxy=xforwarded so KC honors the
          // ACA edge https termination; KC_HOSTNAME is set by the second
          // deployment after we know the final FQDN (see updateHostname).
          command: [
            '/opt/keycloak/bin/kc.sh'
          ]
          args: [
            'start'
            '--http-enabled=true'
            '--hostname-strict=false'
            '--proxy-headers=xforwarded'
          ]
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          env: [
            { name: 'KC_DB', value: 'postgres' }
            { name: 'KC_DB_URL', value: dbJdbcUrl }
            { name: 'KC_DB_USERNAME', value: dbUsername }
            { name: 'KC_DB_PASSWORD', secretRef: 'db-password' }
            { name: 'KC_BOOTSTRAP_ADMIN_USERNAME', value: bootstrapAdminUsername }
            { name: 'KC_BOOTSTRAP_ADMIN_PASSWORD', secretRef: 'admin-password' }
            { name: 'KC_HEALTH_ENABLED', value: 'true' }
            { name: 'KC_METRICS_ENABLED', value: 'true' }
            // Set after first deployment via a follow-up step; for now use
            // an empty value and rely on hostname-strict=false. Foundry +
            // browsers reach the app via the ACA FQDN.
            { name: 'KC_HOSTNAME', value: '' }
          ]
          probes: [
            {
              type: 'Startup'
              httpGet: { path: '/health/started', port: 9000 }
              initialDelaySeconds: 20
              periodSeconds: 10
              failureThreshold: 30
            }
            {
              type: 'Liveness'
              httpGet: { path: '/health/live', port: 9000 }
              periodSeconds: 30
              failureThreshold: 5
            }
            {
              type: 'Readiness'
              httpGet: { path: '/health/ready', port: 9000 }
              periodSeconds: 15
              failureThreshold: 5
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output managedEnvironmentName string = env.name
output managedEnvironmentResourceId string = env.id
output containerAppName string = app.name
output containerAppResourceId string = app.id
output fqdn string = app.properties.configuration.ingress.fqdn
output baseUrl string = 'https://${app.properties.configuration.ingress.fqdn}'
