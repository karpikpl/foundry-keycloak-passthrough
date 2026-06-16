// infra/modules/data/postgres.bicep
// Azure Database for PostgreSQL Flexible Server — backing store for Keycloak.
// Burstable B1ms with public networking + firewall rule allowing Azure
// services. Good enough for a POC; not production-hardened.

@description('Server name (lowercase, 3-63 chars, must be globally unique).')
param name string

@description('Azure region.')
param location string

@description('Tags applied to the server.')
param tags object = {}

@description('Administrator login name.')
param administratorLogin string = 'kcadmin'

@secure()
@description('Administrator password (stored in Key Vault by the caller).')
param administratorPassword string

@description('Database name created on first deploy.')
param databaseName string = 'keycloak'

@description('Postgres major version.')
param version string = '16'

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: version
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    storage: {
      storageSizeGB: 32
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }

  resource db 'databases' = {
    name: databaseName
    properties: {
      charset: 'UTF8'
      collation: 'en_US.utf8'
    }
  }

  // Allow Azure-internal services (incl. Container Apps) to reach the server.
  resource allowAzure 'firewallRules' = {
    name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
    properties: {
      startIpAddress: '0.0.0.0'
      endIpAddress: '0.0.0.0'
    }
  }
}

output serverName string = server.name
output fqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = databaseName
output administratorLogin string = administratorLogin
@description('JDBC URL Keycloak uses to connect (sslmode=require enforced).')
output jdbcUrl string = 'jdbc:postgresql://${server.properties.fullyQualifiedDomainName}:5432/${databaseName}?sslmode=require'
