#!/usr/bin/env bash
# scripts/postprovision.sh — AZD postprovision hook for cloud-helper-keycloak.
#
# Configures the freshly-deployed Keycloak instance:
#   1. Waits for /health/ready
#   2. Creates the realm (idempotent)
#   3. Generates a client secret on the Entra "broker" app registration
#   4. Adds the Keycloak realm broker callback to the Entra app's redirect URIs
#   5. Creates/updates the Entra OIDC identity provider inside Keycloak
#   6. Creates/updates the `mcp-server` Keycloak client (PKCE + secret,
#      with an audience mapper so issued tokens carry `aud=mcp-server`)
#   7. Patches the MCP App Service with KEYCLOAK_* / CLIENT_ID / AUDIENCE
#   8. Creates the Foundry MCP RemoteTool connection pointing at Keycloak
#   9. Adds the Foundry redirect URL to the Keycloak client redirect URIs
#
# All steps are idempotent — re-running azd provision is safe.

set -euo pipefail

# Resolve script directory for sourcing helper python snippets relatively.
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$( cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd )"

require() {
  if [ -z "${!1-}" ]; then
    echo "❌ Missing required env var: $1"
    exit 1
  fi
}

# Inputs (all populated by azd from main.bicep outputs / env)
require AZURE_SUBSCRIPTION_ID
require AZURE_RESOURCE_GROUP
require AZURE_TENANT_ID
require KEYCLOAK_BASE_URL
require KEYCLOAK_REALM
require KEYCLOAK_ADMIN_USERNAME
require KEYCLOAK_ADMIN_PASSWORD
require ENTRA_APP_CLIENT_ID
require FOUNDRY_NAME
require WEB_APP_NAME
require APP_SLOT_HOSTNAME

MCP_CLIENT_ID="${MCP_CLIENT_ID:-mcp-server}"
IDP_ALIAS="${IDP_ALIAS:-entra}"
KC_BROKER_REDIRECT_URI="${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}/broker/${IDP_ALIAS}/endpoint"

banner() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ──────────────────────────────────────────────────────────────────────────────
banner "⏳  Waiting for Keycloak readiness at ${KEYCLOAK_BASE_URL}"
# Keycloak's /health/ready is exposed on the management port (9000), which is
# not published through ACA ingress. Fall back to probing the OIDC discovery
# doc on the master realm — once that responds, Keycloak is fully up.
DISCOVERY_URL="${KEYCLOAK_BASE_URL%/}/realms/master/.well-known/openid-configuration"
for i in $(seq 1 60); do
  if curl -fsS --max-time 5 "${DISCOVERY_URL}" -o /dev/null 2>/dev/null; then
    echo "  ✅  Keycloak is responding (after ${i} attempts)"
    break
  fi
  printf '.'
  sleep 5
done
echo ""
if ! curl -fsS --max-time 5 "${DISCOVERY_URL}" -o /dev/null 2>/dev/null; then
  echo "❌  Keycloak did not become ready in time. Check ACA container logs:"
  echo "    az containerapp logs show -g ${AZURE_RESOURCE_GROUP} -n ${KEYCLOAK_CONTAINER_APP_NAME:-keycloak-*} --type console --tail 200"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
banner "🔑  Obtaining Keycloak master-realm admin token"
ADMIN_TOKEN=$(curl -fsS \
  -d "client_id=admin-cli" \
  -d "username=${KEYCLOAK_ADMIN_USERNAME}" \
  -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  "${KEYCLOAK_BASE_URL%/}/realms/master/protocol/openid-connect/token" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "  ✅  Got admin token"

kc_api() {
  # Usage: kc_api METHOD PATH [BODY]
  local method="$1"; local path="$2"; local body="${3-}"
  local url="${KEYCLOAK_BASE_URL%/}/admin${path}"
  if [ -n "${body}" ]; then
    curl -sS -X "${method}" -H "Authorization: Bearer ${ADMIN_TOKEN}" \
         -H "Content-Type: application/json" --data "${body}" "${url}"
  else
    curl -sS -X "${method}" -H "Authorization: Bearer ${ADMIN_TOKEN}" "${url}"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
banner "🏰  Ensuring realm '${KEYCLOAK_REALM}' exists"
REALM_GET=$(kc_api GET "/realms/${KEYCLOAK_REALM}" 2>/dev/null || true)
if echo "${REALM_GET}" | grep -q '"realm"'; then
  echo "  ✅  Realm already exists"
else
  REALM_BODY=$(python3 -c "import json; print(json.dumps({'realm':'${KEYCLOAK_REALM}','enabled':True,'displayName':'MCP Demo'}))")
  kc_api POST "/realms" "${REALM_BODY}" > /dev/null
  echo "  ✅  Realm created"
fi

# ──────────────────────────────────────────────────────────────────────────────
banner "🔐  Generating Entra app client secret"
# `az ad app credential reset` generates the secret. We pass --append so we
# can clean up older secrets afterwards using `az ad app credential delete`,
# which is safer than PATCH-replacing passwordCredentials wholesale (Graph
# read-after-write replication lag can otherwise wipe the new secret).
RESET_JSON=$(az ad app credential reset \
  --id "${ENTRA_APP_CLIENT_ID}" \
  --display-name "keycloak-idp-secret" \
  --years 1 \
  --append \
  --output json)
ENTRA_CLIENT_SECRET=$(echo "${RESET_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
KEEP_KEY_ID=$(echo "${RESET_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('keyId',''))" 2>/dev/null || true)
echo "  ✅  Secret generated (keyId=${KEEP_KEY_ID:0:8}...)"

# Prune older 'keycloak-idp-secret' credentials individually. Skip if Graph
# hasn't yet propagated the new credential (so we never accidentally remove
# the one we just created).
APP_OBJ_ID=$(az ad app show --id "${ENTRA_APP_CLIENT_ID}" --query id -o tsv)
if [ -n "${APP_OBJ_ID}" ] && [ -n "${KEEP_KEY_ID}" ]; then
  for attempt in 1 2 3 4 5; do
    CREDS_JSON=$(az rest --method GET \
      --url "https://graph.microsoft.com/v1.0/applications/${APP_OBJ_ID}" \
      --query passwordCredentials -o json)
    SAW_KEEP=$(CREDS_JSON="${CREDS_JSON}" KEEP_KEY_ID="${KEEP_KEY_ID}" python3 -c "
import json,os
creds=json.loads(os.environ['CREDS_JSON'])
print('1' if any(c.get('keyId')==os.environ['KEEP_KEY_ID'] for c in creds) else '0')
")
    if [ "${SAW_KEEP}" = "1" ]; then break; fi
    sleep 3
  done

  if [ "${SAW_KEEP}" = "1" ]; then
    OLD_KEY_IDS=$(CREDS_JSON="${CREDS_JSON}" KEEP_KEY_ID="${KEEP_KEY_ID}" python3 -c "
import json,os
creds=json.loads(os.environ['CREDS_JSON'])
keep=os.environ['KEEP_KEY_ID']
print(' '.join(c['keyId'] for c in creds
                if c.get('displayName')=='keycloak-idp-secret'
                and c.get('keyId')!=keep))
")
    for kid in ${OLD_KEY_IDS}; do
      az ad app credential delete --id "${ENTRA_APP_CLIENT_ID}" --key-id "${kid}" > /dev/null 2>&1 || true
    done
  else
    echo "  ⚠️  Graph did not return the new credential after retries — skipping prune"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
banner "🔁  Ensuring Keycloak broker redirect URI is registered on Entra app"
CURRENT_WEB_URIS=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/applications/${APP_OBJ_ID}" \
  --query "web.redirectUris" -o json)
UPDATED_WEB_URIS=$(CURRENT="${CURRENT_WEB_URIS}" URI="${KC_BROKER_REDIRECT_URI}" \
  python3 -c "
import json,os
u=json.loads(os.environ['CURRENT'])
r=os.environ['URI']
if r not in u: u.append(r)
print(json.dumps(u))
")
az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/applications/${APP_OBJ_ID}" \
  --headers "Content-Type=application/json" \
  --body "{\"web\":{\"redirectUris\":${UPDATED_WEB_URIS}}}" > /dev/null
echo "  ✅  ${KC_BROKER_REDIRECT_URI}"

# ──────────────────────────────────────────────────────────────────────────────
banner "🔗  Configuring Keycloak → Entra OIDC identity provider broker"
ENTRA_AUTHZ="https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/authorize"
ENTRA_TOKEN="https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token"
ENTRA_USERINFO="https://graph.microsoft.com/oidc/userinfo"
ENTRA_JWKS="https://login.microsoftonline.com/${AZURE_TENANT_ID}/discovery/v2.0/keys"
ENTRA_ISSUER="https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0"

IDP_BODY=$(CLIENT_ID="${ENTRA_APP_CLIENT_ID}" CLIENT_SECRET="${ENTRA_CLIENT_SECRET}" \
           AUTHZ="${ENTRA_AUTHZ}" TOKEN="${ENTRA_TOKEN}" USERINFO="${ENTRA_USERINFO}" \
           JWKS="${ENTRA_JWKS}" ISSUER="${ENTRA_ISSUER}" ALIAS="${IDP_ALIAS}" \
           python3 -c "
import json,os
print(json.dumps({
  'alias': os.environ['ALIAS'],
  'displayName': 'Microsoft Entra ID',
  'providerId': 'oidc',
  'enabled': True,
  'updateProfileFirstLoginMode': 'on',
  'trustEmail': True,
  'storeToken': False,
  'addReadTokenRoleOnCreate': False,
  'authenticateByDefault': False,
  'linkOnly': False,
  'firstBrokerLoginFlowAlias': 'first broker login',
  'config': {
    'clientId': os.environ['CLIENT_ID'],
    'clientSecret': os.environ['CLIENT_SECRET'],
    'clientAuthMethod': 'client_secret_post',
    'authorizationUrl': os.environ['AUTHZ'],
    'tokenUrl': os.environ['TOKEN'],
    'userInfoUrl': os.environ['USERINFO'],
    'jwksUrl': os.environ['JWKS'],
    'issuer': os.environ['ISSUER'],
    'defaultScope': 'openid profile email',
    'validateSignature': 'true',
    'useJwksUrl': 'true',
    'syncMode': 'IMPORT',
    'pkceEnabled': 'true',
    'pkceMethod': 'S256'
  }
}))")

IDP_EXISTS=$(kc_api GET "/realms/${KEYCLOAK_REALM}/identity-provider/instances/${IDP_ALIAS}" 2>/dev/null | grep -c '"alias"' || true)
if [ "${IDP_EXISTS}" = "1" ]; then
  kc_api PUT "/realms/${KEYCLOAK_REALM}/identity-provider/instances/${IDP_ALIAS}" "${IDP_BODY}" > /dev/null
  echo "  ✅  IdP '${IDP_ALIAS}' updated"
else
  kc_api POST "/realms/${KEYCLOAK_REALM}/identity-provider/instances" "${IDP_BODY}" > /dev/null
  echo "  ✅  IdP '${IDP_ALIAS}' created"
fi

# ──────────────────────────────────────────────────────────────────────────────
banner "🛠️   Ensuring Keycloak client '${MCP_CLIENT_ID}' exists"
EXISTING_CLIENT=$(kc_api GET "/realms/${KEYCLOAK_REALM}/clients?clientId=${MCP_CLIENT_ID}")
CLIENT_UUID=$(echo "${EXISTING_CLIENT}" | python3 -c "import sys,json; a=json.load(sys.stdin); print(a[0]['id'] if a else '')" 2>/dev/null || true)

CLIENT_REDIRECTS=$(python3 -c "
import json
print(json.dumps([
  'https://ai.azure.com/*',
  'https://vscode.dev/redirect',
  'http://localhost:55899/callback',
  'http://127.0.0.1:55899/callback'
]))")

CLIENT_BODY=$(CID="${MCP_CLIENT_ID}" REDIRECTS="${CLIENT_REDIRECTS}" python3 -c "
import json,os
print(json.dumps({
  'clientId': os.environ['CID'],
  'enabled': True,
  'protocol': 'openid-connect',
  'publicClient': False,
  'clientAuthenticatorType': 'client-secret',
  'standardFlowEnabled': True,
  'directAccessGrantsEnabled': False,
  'serviceAccountsEnabled': False,
  'redirectUris': json.loads(os.environ['REDIRECTS']),
  'webOrigins': ['+'],
  'attributes': {
    'pkce.code.challenge.method': 'S256'
  }
}))")

if [ -z "${CLIENT_UUID}" ]; then
  kc_api POST "/realms/${KEYCLOAK_REALM}/clients" "${CLIENT_BODY}" > /dev/null
  CLIENT_UUID=$(kc_api GET "/realms/${KEYCLOAK_REALM}/clients?clientId=${MCP_CLIENT_ID}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
  echo "  ✅  Client created (uuid=${CLIENT_UUID})"
else
  kc_api PUT "/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}" "${CLIENT_BODY}" > /dev/null
  echo "  ✅  Client updated (uuid=${CLIENT_UUID})"
fi

# Realm client-scope `mcp.access` — issued by default to mcp-server tokens,
# carries an audience mapper so access tokens get aud=mcp-server.
SCOPE_NAME="mcp.access"
EXISTING_SCOPES=$(kc_api GET "/realms/${KEYCLOAK_REALM}/client-scopes")
SCOPE_UUID=$(echo "${EXISTING_SCOPES}" | NAME="${SCOPE_NAME}" python3 -c "
import sys,json,os
ss=json.load(sys.stdin)
m=[s for s in ss if s.get('name')==os.environ['NAME']]
print(m[0]['id'] if m else '')
")
SCOPE_BODY=$(NAME="${SCOPE_NAME}" python3 -c "
import json,os
print(json.dumps({
  'name': os.environ['NAME'],
  'description': 'Grants access to the MCP server',
  'protocol': 'openid-connect',
  'attributes': {
    'include.in.token.scope': 'true',
    'display.on.consent.screen': 'true'
  }
}))")
if [ -z "${SCOPE_UUID}" ]; then
  kc_api POST "/realms/${KEYCLOAK_REALM}/client-scopes" "${SCOPE_BODY}" > /dev/null
  SCOPE_UUID=$(kc_api GET "/realms/${KEYCLOAK_REALM}/client-scopes" \
    | NAME="${SCOPE_NAME}" python3 -c "
import sys,json,os
ss=json.load(sys.stdin)
print([s for s in ss if s.get('name')==os.environ['NAME']][0]['id'])
")
  echo "  ✅  Client-scope '${SCOPE_NAME}' created"
else
  kc_api PUT "/realms/${KEYCLOAK_REALM}/client-scopes/${SCOPE_UUID}" "${SCOPE_BODY}" > /dev/null
fi

# Audience mapper attached to the client-scope (not the client) — this keeps
# the scope self-contained: issuing the scope also stamps aud=mcp-server.
MAPPER_NAME="mcp-audience"
MAPPER_BODY=$(CID="${MCP_CLIENT_ID}" NAME="${MAPPER_NAME}" python3 -c "
import json,os
print(json.dumps({
  'name': os.environ['NAME'],
  'protocol': 'openid-connect',
  'protocolMapper': 'oidc-audience-mapper',
  'config': {
    'included.client.audience': os.environ['CID'],
    'id.token.claim': 'false',
    'access.token.claim': 'true'
  }
}))")
EXISTING_SCOPE_MAPPERS=$(kc_api GET "/realms/${KEYCLOAK_REALM}/client-scopes/${SCOPE_UUID}/protocol-mappers/models")
HAS_SCOPE_MAPPER=$(echo "${EXISTING_SCOPE_MAPPERS}" | NAME="${MAPPER_NAME}" python3 -c "
import sys,json,os
ms=json.load(sys.stdin)
print('1' if any(m.get('name')==os.environ['NAME'] for m in ms) else '0')
")
if [ "${HAS_SCOPE_MAPPER}" = "0" ]; then
  kc_api POST "/realms/${KEYCLOAK_REALM}/client-scopes/${SCOPE_UUID}/protocol-mappers/models" "${MAPPER_BODY}" > /dev/null
  echo "  ✅  Audience mapper attached to client-scope"
fi

# Assign the scope as a default client scope on mcp-server.
kc_api PUT "/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/default-client-scopes/${SCOPE_UUID}" "" > /dev/null 2>&1 || true
echo "  ✅  Client-scope '${SCOPE_NAME}' assigned as default to ${MCP_CLIENT_ID}"

# If we previously attached the audience mapper directly to the client,
# remove it — it's now on the scope and would otherwise be a duplicate.
EXISTING_CLIENT_MAPPERS=$(kc_api GET "/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/protocol-mappers/models")
DUP_MAPPER_ID=$(echo "${EXISTING_CLIENT_MAPPERS}" | NAME="${MAPPER_NAME}" python3 -c "
import sys,json,os
ms=json.load(sys.stdin)
m=[x for x in ms if x.get('name')==os.environ['NAME']]
print(m[0]['id'] if m else '')
")
if [ -n "${DUP_MAPPER_ID}" ]; then
  kc_api DELETE "/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/protocol-mappers/models/${DUP_MAPPER_ID}" > /dev/null 2>&1 || true
fi

# Get/regenerate client secret.
SECRET_JSON=$(kc_api GET "/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/client-secret")
MCP_CLIENT_SECRET=$(echo "${SECRET_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('value',''))")
if [ -z "${MCP_CLIENT_SECRET}" ]; then
  MCP_CLIENT_SECRET=$(kc_api POST "/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/client-secret" "" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")
fi
echo "  ✅  Client secret retrieved"

# ──────────────────────────────────────────────────────────────────────────────
banner "🌐  Updating MCP App Service settings for Keycloak"
az webapp config appsettings set \
  --resource-group "${AZURE_RESOURCE_GROUP}" \
  --name "${WEB_APP_NAME}" \
  --settings \
    "KEYCLOAK_BASE_URL=${KEYCLOAK_BASE_URL}" \
    "KEYCLOAK_REALM=${KEYCLOAK_REALM}" \
    "CLIENT_ID=${MCP_CLIENT_ID}" \
    "AUDIENCE=${MCP_CLIENT_ID}" \
    "RESOURCE_HOST=${APP_SLOT_HOSTNAME}" \
  --output none
echo "  ✅  App settings updated"

# ──────────────────────────────────────────────────────────────────────────────
banner "🔗  Foundry MCP Connection (Keycloak as authorization server)"
CONNECTION_NAME="$(echo "${WEB_APP_NAME}" | cut -c1-23)"
CONNECTION_URL="https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${FOUNDRY_NAME}/connections/${CONNECTION_NAME}?api-version=2025-09-01"

BODY=$(MCP_HOST="${APP_SLOT_HOSTNAME}" CID="${MCP_CLIENT_ID}" SEC="${MCP_CLIENT_SECRET}" \
       AUTHZ="${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth" \
       TOKEN="${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
       python3 -c "
import json,os
print(json.dumps({
  'properties': {
    'target': f\"https://{os.environ['MCP_HOST']}/mcp\",
    'authType': 'OAuth2',
    'category': 'RemoteTool',
    'metadata': { 'type': 'custom_MCP' },
    'credentials': {
      'clientId': os.environ['CID'],
      'clientSecret': os.environ['SEC']
    },
    'tokenUrl': os.environ['TOKEN'],
    'authorizationUrl': os.environ['AUTHZ'],
    'refreshUrl': os.environ['TOKEN'],
    'scopes': ['openid', 'profile', 'email', 'mcp.access']
  }
}))")

echo "  🔍  Checking for existing connection..."
EXISTING=$(az rest --method GET --url "${CONNECTION_URL}" -o json 2>/dev/null) || true
EXISTING_REDIRECT=$(echo "${EXISTING}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('properties',{}).get('redirectUrl',''))" 2>/dev/null) || true

if [ -n "$EXISTING_REDIRECT" ] && [ "$EXISTING_REDIRECT" != "None" ]; then
  echo "  ✅  Connection exists with redirectUrl: $EXISTING_REDIRECT"
  REDIRECT_URL="$EXISTING_REDIRECT"
  # Refresh credentials in case the client secret was rotated.
  az rest --method PUT --url "${CONNECTION_URL}" \
    --body "${BODY}" --headers "Content-Type=application/json" -o none 2>/dev/null || true
else
  if [ -n "$EXISTING" ]; then
    echo "  🗑️  Deleting existing connection without redirectUrl..."
    az rest --method DELETE --url "${CONNECTION_URL}" 2>/dev/null || true
    sleep 5
  fi
  REDIRECT_URL=""
  for CONN_NAME in "${CONNECTION_NAME}" "${CONNECTION_NAME}-$(date +%s | tail -c 5)"; do
    CONN_URL="https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${FOUNDRY_NAME}/connections/${CONN_NAME}?api-version=2025-09-01"
    echo "  📤  PUT ${CONN_URL}"
    RESPONSE=$(az rest --method PUT --url "${CONN_URL}" --body "${BODY}" \
      --headers "Content-Type=application/json" -o json 2>&1) || true
    REDIRECT_URL=$(echo "${RESPONSE}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('properties',{}).get('redirectUrl',''))" 2>/dev/null) || true
    if [ -n "$REDIRECT_URL" ] && [ "$REDIRECT_URL" != "None" ]; then
      echo "  ✅  Created connection: ${CONN_NAME}"
      CONNECTION_NAME="${CONN_NAME}"
      break
    fi
    echo "  ⚠️  Failed, trying fallback name..."
  done
fi

if [ -n "$REDIRECT_URL" ] && [ "$REDIRECT_URL" != "None" ]; then
  echo "  ✅  redirectUrl: $REDIRECT_URL"
  echo "  🔧  Adding Foundry redirect to Keycloak client redirect URIs..."
  EXISTING_CLIENT_JSON=$(kc_api GET "/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}")
  UPDATED_CLIENT=$(CLIENT="${EXISTING_CLIENT_JSON}" URL="${REDIRECT_URL}" python3 -c "
import json,os
c=json.loads(os.environ['CLIENT'])
uris=c.get('redirectUris',[])
if os.environ['URL'] not in uris:
  uris.append(os.environ['URL'])
  c['redirectUris']=uris
print(json.dumps(c))
")
  kc_api PUT "/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}" "${UPDATED_CLIENT}" > /dev/null
  echo "  ✅  Keycloak client updated with Foundry redirect"
else
  echo "  ⚠️  No redirectUrl returned from Foundry — connection may still be provisioning."
fi

# Persist outputs for postdeploy & the developer.
azd env set MCP_CLIENT_ID "${MCP_CLIENT_ID}" > /dev/null
azd env set MCP_CLIENT_SECRET "${MCP_CLIENT_SECRET}" > /dev/null
azd env set FOUNDRY_CONNECTION_NAME "${CONNECTION_NAME}" > /dev/null

echo ""
echo "✅  Keycloak postprovision complete."
echo ""
echo "  Keycloak URL : ${KEYCLOAK_BASE_URL}"
echo "  Realm        : ${KEYCLOAK_REALM}"
echo "  Admin login  : ${KEYCLOAK_BASE_URL%/}/admin/  (user: ${KEYCLOAK_ADMIN_USERNAME})"
echo "  MCP endpoint : https://${APP_SLOT_HOSTNAME}/mcp"
echo ""
echo "  Entra app    : ${ENTRA_APP_CLIENT_ID}  (display: ${ENTRA_APP_DISPLAY_NAME:-keycloak-broker})"
echo "                  • secret 'keycloak-idp-secret' was just rotated and pushed to Keycloak."
echo "                  • Microsoft Entra needs ~30–90s to fully propagate a new secret."
echo "                    If the first login attempt returns AADSTS7000215, wait a minute and retry."
echo ""
echo "  Foundry conn : ${CONNECTION_NAME}"
echo ""
echo "  Try it       : cd client && uv run test_client.py --idp-hint entra"
echo ""
