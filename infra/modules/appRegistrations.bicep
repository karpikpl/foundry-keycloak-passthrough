// infra/modules/appRegistrations.bicep
// Updated for the Keycloak-passthrough demo (2026-06-15).
//
// In this variant Entra is NOT the OAuth authorization server for the MCP
// server — Keycloak is. The single Entra app registration created here is the
// upstream OIDC identity provider that Keycloak federates with (Keycloak IdP
// broker).
//
// Bicep only creates the app shell. Two things are completed by the AZD
// postprovision hook once the Keycloak ACA FQDN is known:
//   1. `az ad app credential reset` — generates the client secret that
//      Keycloak's IdP config needs (Graph Bicep cannot return secret text).
//   2. PATCH `web.redirectUris` to add
//      https://<kc-host>/realms/<realm>/broker/<alias>/endpoint.

extension microsoftGraphV1

@description('Environment name — used to suffix the app display name so parallel AZD envs do not clash.')
param environmentName string

var name = 'keycloak-broker-${environmentName}'

resource app 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: name
  displayName: name
  signInAudience: 'AzureADMyOrg'

  web: {
    implicitGrantSettings: {
      enableAccessTokenIssuance: false
      enableIdTokenIssuance: false
    }
  }
}

resource servicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: app.appId
  accountEnabled: true
}

@description('Client ID of the Entra app that Keycloak uses as its upstream IdP.')
output clientId string = app.appId

@description('Display name of the Entra app.')
output appDisplayName string = app.displayName


