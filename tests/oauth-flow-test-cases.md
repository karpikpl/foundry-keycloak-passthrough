# OAuth Flow — Test Cases (Keycloak realm + Entra IdP broker)

**Project:** cloud-helper-keycloak (FastMCP on Azure App Service, Keycloak on Azure Container Apps)
**Scope:** End-to-end OAuth flows where Keycloak is the authorization server and Entra is federated as an upstream OIDC IdP.
**Status:** Ready for execution — fill in *Actual* and *Pass/Fail* during a test run.

---

## Environment

```bash
# Populated by `azd env get-values` after `azd up`
SERVER_URL="https://<web-app>.azurewebsites.net/mcp"
KEYCLOAK_BASE_URL="https://<keycloak-aca-fqdn>"
KEYCLOAK_REALM="mcp-demo"
CLIENT_ID="mcp-server"
CLIENT_SECRET="<from azd env get-values MCP_CLIENT_SECRET>"
CALLBACK_PORT="55899"

DISCOVERY_URL="${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration"
AUTHORIZATION_URL="${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth"
TOKEN_URL="${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
JWKS_URL="${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs"
PROTECTED_RESOURCE_URL="${SERVER_URL%/mcp}/.well-known/oauth-protected-resource"
```

PKCE test values (deterministic for repeat runs):

```bash
CODE_VERIFIER="dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
CODE_CHALLENGE="E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
# challenge method: S256
```

---

## TC-01 — Realm discovery & JWKS reachable

**Type:** Smoke / Happy path · **Priority:** P0

```bash
curl -fsS "${DISCOVERY_URL}" | jq '{issuer, authorization_endpoint, token_endpoint, jwks_uri}'
curl -fsS "${JWKS_URL}" | jq '.keys | length'
```

**Pass:** `issuer == ${KEYCLOAK_BASE_URL}/realms/${KEYCLOAK_REALM}`, JWKS returns ≥ 1 RSA key.

---

## TC-02 — MCP Protected Resource Metadata advertises the realm

**Type:** Spec compliance (RFC 9728) · **Priority:** P0

```bash
curl -fsS "${PROTECTED_RESOURCE_URL}" | jq
```

**Pass:** `authorization_servers[0]` equals the realm issuer; `resource` ends with `/mcp`; `scopes_supported` lists at least one `<resource>/mcp.access` entry.

---

## TC-03 — Full PKCE flow (local Keycloak login)

**Type:** Happy path · **Priority:** P0

```bash
cd client && uv run test_client.py
# When the Keycloak login page renders, sign in as the local realm user
# (or as the bootstrap admin if you created a user mapping for them).
```

**Pass:** Console prints tools list, `hello` tool returns the caller's claims, and `aud` includes `mcp-server`.

---

## TC-04 — Full PKCE flow with Entra federation (`kc_idp_hint=entra`)

**Type:** Federation happy path · **Priority:** P0

```bash
cd client && uv run test_client.py --idp-hint entra
```

**Pass:** Browser is redirected straight to `login.microsoftonline.com` (Keycloak does not show its own form). After consenting, the test client receives a Keycloak token whose `email`/`preferred_username` claim matches the Entra account that signed in.

---

## TC-05 — Foundry MCP connection — ARM resource exists

**Type:** Connection presence · **Priority:** P0

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${FOUNDRY_NAME}/connections/${FOUNDRY_CONNECTION_NAME}?api-version=2025-09-01" \
  | jq '.properties | {target, authType, authorizationUrl, tokenUrl, scopes, redirectUrl}'
```

**Pass:** `authType=OAuth2`, `tokenUrl` and `authorizationUrl` point at the Keycloak realm endpoints, `redirectUrl` is non-empty and starts with `https://`.

---

## TC-06 — Foundry agent — whoami round-trip

**Type:** End-to-end passthrough · **Priority:** P0

```bash
cd agent_v2 && uv run agent.py --prompt "Call whoami and return the claims verbatim."
```

**Pass:** Agent output includes the signed-in Entra user's UPN (because Keycloak imports it from the upstream id_token). No `401` from the MCP server.

---

## TC-07 — Token rejected when audience mapper missing

**Type:** Negative · **Priority:** P1

Manually delete the `mcp-audience` protocol mapper from the Keycloak client, redeploy a fresh access token, and call the MCP server.

```bash
curl -i -H "Authorization: Bearer <bad_token>" "${SERVER_URL}"
```

**Pass:** MCP server returns HTTP 401 with `WWW-Authenticate: Bearer error="invalid_token"`. Re-running `scripts/postprovision.sh` restores the mapper and recovers the flow.

---

## TC-08 — Token rejected when issuer mismatches

**Type:** Negative · **Priority:** P1

Mint a token from the **master** realm (`/realms/master/protocol/openid-connect/token`) and call the MCP server with it.

**Pass:** HTTP 401, `error="invalid_token"`, error description references the issuer mismatch.

---

## TC-09 — Postprovision is idempotent

**Type:** Operational · **Priority:** P1

```bash
azd hooks run postprovision   # run twice in a row
```

**Pass:** Second run completes without errors and does not duplicate the realm, the IdP, the client, the audience mapper, or redirect URIs. Foundry connection retains its `redirectUrl`.

---

## TC-10 — Keycloak admin login

**Type:** Sanity · **Priority:** P2

Open `${KEYCLOAK_BASE_URL}/admin/` and sign in with `${KEYCLOAK_ADMIN_USERNAME}` / the value stored under `KEYCLOAK_ADMIN_PASSWORD`.

**Pass:** Admin console loads, realms `master` and `mcp-demo` are visible, the `mcp-demo` realm shows the `entra` identity provider and the `mcp-server` client.

---

## Result template

| TC | Result | Notes |
|----|--------|-------|
| TC-01 | ⏳ | |
| TC-02 | ⏳ | |
| TC-03 | ⏳ | |
| TC-04 | ⏳ | |
| TC-05 | ⏳ | |
| TC-06 | ⏳ | |
| TC-07 | ⏳ | |
| TC-08 | ⏳ | |
| TC-09 | ⏳ | |
| TC-10 | ⏳ | |
