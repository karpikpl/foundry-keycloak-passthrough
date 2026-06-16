using 'main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', '')
param existingPlanName = readEnvironmentVariable('EXISTING_PLAN_NAME', '')
param chatDeploymentName = readEnvironmentVariable('AZURE_OPENAI_CHAT_DEPLOYMENT_NAME', 'gpt-4o')
param foundryPublicNetworkAccess = readEnvironmentVariable('FOUNDRY_PUBLIC_NETWORK_ACCESS', 'Enabled')

param keycloakRealm = readEnvironmentVariable('KEYCLOAK_REALM', 'mcp-demo')
param keycloakAdminUsername = readEnvironmentVariable('KEYCLOAK_ADMIN_USERNAME', 'admin')
param keycloakAdminPassword = readEnvironmentVariable('KEYCLOAK_ADMIN_PASSWORD', '')
param postgresAdminPassword = readEnvironmentVariable('POSTGRES_ADMIN_PASSWORD', '')

