#!/usr/bin/env bash
# scripts/smoke.sh — quick post-deploy smoke check.
# Verifies Keycloak realm discovery, JWKS, and MCP Protected Resource Metadata.
# Reads values from `azd env get-values`, so run it from the repo root after
# `azd up` has succeeded.

set -euo pipefail

eval "$(azd env get-values | grep -E '^(APP_SLOT_HOSTNAME|KEYCLOAK_BASE_URL|KEYCLOAK_REALM)=')"

if [ -z "${KEYCLOAK_BASE_URL:-}" ]; then
  echo "❌ KEYCLOAK_BASE_URL not set — run 'azd up' first."
  exit 1
fi

DISCOVERY_URL="${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration"
JWKS_URL="${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs"
PRM_URL="https://${APP_SLOT_HOSTNAME}/.well-known/oauth-protected-resource"

pass=0; fail=0
check() {
  local name="$1"; local cmd="$2"
  if eval "$cmd" > /tmp/smoke.out 2>&1; then
    echo "  ✅  $name"
    pass=$((pass+1))
  else
    echo "  ❌  $name"
    sed 's/^/      /' /tmp/smoke.out | head -10
    fail=$((fail+1))
  fi
}

echo ""
echo "🔎  Keycloak: ${KEYCLOAK_BASE_URL}  (realm: ${KEYCLOAK_REALM})"
check "OIDC discovery responds"            "curl -fsS '${DISCOVERY_URL}' -o /dev/null"
check "JWKS contains at least one key"     "curl -fsS '${JWKS_URL}' | jq -e '.keys | length > 0' >/dev/null"
check "Discovery issuer matches realm URL" "curl -fsS '${DISCOVERY_URL}' | jq -e '.issuer == \"${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}\"' >/dev/null"

echo ""
echo "🔎  MCP server: https://${APP_SLOT_HOSTNAME}"
check "Protected Resource Metadata reachable"      "curl -fsS '${PRM_URL}' -o /dev/null"
check "PRM advertises Keycloak realm as auth srv"  "curl -fsS '${PRM_URL}' | jq -e --arg iss \"${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}\" '.authorization_servers | index(\$iss) != null' >/dev/null"
check "PRM resource ends with /mcp"                "curl -fsS '${PRM_URL}' | jq -e '.resource | endswith(\"/mcp\")' >/dev/null"

echo ""
echo "📊  ${pass} passed, ${fail} failed"
exit "${fail}"
