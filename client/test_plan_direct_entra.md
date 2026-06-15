# Direct-Entra Test Plan

This plan defines QA sign-off for the `investigate/direct-entra-pattern` branch. The target architecture is **resource-server mode**: VS Code and the Python test client obtain access tokens **directly from Entra**, then call the MCP server with that bearer token. No OAuth proxy and no Dynamic Client Registration (DCR).

## Test variables

Set these once and reuse them in all commands:

```bash
export BASE_URL="https://<app-service-host>"
export MCP_URL="$BASE_URL/mcp"
export TENANT_ID="<entra-tenant-guid>"
export SERVER_CLIENT_ID="<server-app-registration-guid>"
export SCOPE="api://$SERVER_CLIENT_ID/mcp.access"
export VSCODE_CLIENT_ID="aebc6443-996d-45c2-90f0-388ff96faa56"
```

---

## 1. Pre-flight checks (before testing VS Code)

### 1.1 Verify the MCP server starts without errors

**Local start**

```bash
cd server
uv run python server.py
```

**Pass criteria**
- Process stays up
- No import/config exception on startup
- Server listens on expected port and serves `/mcp`

**Quick probe**

```bash
curl -i http://127.0.0.1:8000/mcp
```

**Expected**
- `401 Unauthorized` is acceptable before auth
- Do **not** accept a crash, stack trace, or connection refusal
- Prefer a `WWW-Authenticate: Bearer ...` header advertising auth metadata

### 1.2 Verify `/.well-known/oauth-authorization-server`

```bash
curl -fsS "$BASE_URL/.well-known/oauth-authorization-server" | python -m json.tool
```

**Pass criteria**
- JSON is valid
- `issuer` points to `https://login.microsoftonline.com/$TENANT_ID/v2.0`
- `authorization_endpoint` points to `https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/authorize`
- `token_endpoint` points to `https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token`
- No local `/auth/authorize`, `/auth/token`, or `/register` URLs are advertised
- Scope metadata includes or is consistent with `api://$SERVER_CLIENT_ID/mcp.access`

### 1.3 Verify `/.well-known/oauth-protected-resource` (if implemented)

```bash
curl -fsS "$BASE_URL/.well-known/oauth-protected-resource" | python -m json.tool
```

**Pass criteria**
- JSON is valid
- `resource` matches `$BASE_URL` (or the resource URL the server expects)
- `authorization_servers` includes Entra for this tenant
- Metadata points clients at Entra, not at local proxy endpoints

### 1.4 Verify the unauthenticated MCP response advertises PRM

```bash
curl -i "$MCP_URL"
```

**Pass criteria**
- `401 Unauthorized`
- `WWW-Authenticate: Bearer ...`
- If PRM is implemented, the header includes `resource_metadata="$BASE_URL/.well-known/oauth-protected-resource"`

**Pre-flight stop conditions**
- Server does not start
- Any well-known endpoint returns non-JSON or local proxy URLs
- `/mcp` redirects to login instead of returning `401`

---

## 2. Test Client validation (automated)

File: `client/test_client.py`

### Required updates for direct-Entra
- **Do not use DCR.** Entra does not support Dynamic Client Registration for this flow.
- The test client must always pass a **pre-registered** `client_id` into `fastmcp.client.auth.OAuth(...)`.
- Default public client should be **VS Code's client ID** (`aebc6443-996d-45c2-90f0-388ff96faa56`) unless `TEST_CLIENT_ID` / `--client-id` overrides it.
- Requested scope must be exactly:

```text
api://{SERVER_CLIENT_ID}/mcp.access
```

- Expected happy path:
  1. Browser opens Entra authorize URL
  2. User signs in
  3. Client exchanges auth code for token
  4. Client calls MCP tool successfully
  5. Client prints token claims showing `name`, `preferred_username`/`upn`, and `oid`

### Automated command to run

```bash
cd client
uv run test_client.py direct \
  --server-url "$MCP_URL" \
  --server-client-id "$SERVER_CLIENT_ID" \
  --scope "$SCOPE" \
  --client-id "$VSCODE_CLIENT_ID"
```

If the VS Code client ID cannot complete localhost callback in CLI automation, rerun with a **dedicated pre-registered public test client** instead of `aebc...`.

### Expected success output
- `✅ Direct Entra flow succeeded`
- Tool list returns at least one tool
- `hello_world` (or `hello`) returns `200`-equivalent MCP success
- Printed token claims include:
  - `name`
  - `preferred_username` or `upn`
  - `oid`
  - `aud == SERVER_CLIENT_ID` (or resource app ID URI if intentionally dual-audience)
  - `scp` contains `mcp.access`

### Expected failure signatures
- `invalid_client` / `client not found` → wrong public client ID
- `AADSTS65001` / consent required → wrong scope or missing pre-authorization
- `AADSTS50011` → redirect URI mismatch for the chosen public client
- `401` on MCP call after token success → audience/scope/server-side JWT validation issue

---

## 3. VS Code validation (manual — step by step)

This is the **critical sign-off test**.

### 3.1 Configure `.vscode/mcp.json`

Use the MCP endpoint URL and explicit OAuth scope. Do **not** send a `resource` parameter.

```json
{
  "servers": {
    "cloudHelperDirectEntra": {
      "type": "http",
      "url": "https://<app-service-host>/mcp",
      "auth": {
        "method": "oauth2",
        "clientId": "aebc6443-996d-45c2-90f0-388ff96faa56",
        "scopes": ["api://<SERVER_CLIENT_ID>/mcp.access"]
      }
    }
  }
}
```

**Validation rules**
- `url` must be the MCP endpoint (`/mcp`)
- `clientId` must be VS Code's public client ID unless intentionally testing another pre-registered client
- `scopes` must contain only the API scope needed for MCP
- Do **not** add `resource`
- Do **not** add DCR-related configuration

### 3.2 Open DevTools Network tab
1. In VS Code, open **Help → Toggle Developer Tools**
2. Open the **Network** tab
3. Clear existing traffic
4. Filter on: `mcp`, `well-known`, `login.microsoftonline.com`, `oauth`, `token`

### 3.3 Expected network sequence

1. `POST` or initial request to `https://<app-service-host>/mcp`
   - expected: `401 Unauthorized`
2. `GET /.well-known/oauth-protected-resource`
   - expected: `200`
3. `GET /.well-known/oauth-authorization-server` or Entra OIDC metadata
   - expected: `200`
4. `GET https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize?...`
   - expected: interactive sign-in
   - verify query contains:
     - `client_id=aebc6443-996d-45c2-90f0-388ff96faa56`
     - `scope=api://<SERVER_CLIENT_ID>/mcp.access`
     - PKCE fields (`code_challenge`, `code_challenge_method=S256`)
   - verify query **does not** contain `resource=`
5. `POST https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token`
   - expected: `200`
6. MCP retry to `https://<app-service-host>/mcp`
   - expected: `200`
7. Tool call (`tools/call`) for `hello_world` or `hello`
   - expected: `200`

### 3.4 What success looks like
- Final MCP tool call returns `200`
- Tool response includes user identity fields, for example:
  - `Name: ...`
  - `UPN: ...`
  - `OID: ...`
- No consent prompt appears if pre-authorization is correct
- No `resource` parameter appears in the Entra authorize request
- No calls are made to local `/auth/register`, `/auth/authorize`, or `/auth/token`

### 3.5 What failure looks like and how to diagnose it
- **Authorize request fails**: inspect Entra error code in redirect page or network response
- **Token request fails**: inspect `scope`, `client_id`, redirect URI, and consent/pre-auth state
- **Token succeeds but `/mcp` returns 401**: inspect token `aud`, `scp`, `iss`, and server `AZURE_CLIENT_ID` / audience config
- **Consent prompt appears unexpectedly**: client ID is probably missing from `preAuthorizedApplications`
- **No PRM lookup happens**: server did not return the expected `401 + WWW-Authenticate` metadata hint

---

## 4. Failure mode matrix

| Scenario | Expected error | Diagnosis |
|----------|---------------|-----------|
| VS Code client ID not in `preAuthorizedApplications` | `AADSTS65002` or consent prompt | Add VS Code client ID to **Expose an API → Authorized client applications** |
| VS Code client ID not in EasyAuth `allowedClientApplications` | `401` from App Service | Add same client ID to EasyAuth allowed client applications |
| Wrong scope requested | `AADSTS65001` or token invalid | Check `scopes` in `mcp.json` and CLI `--scope`; must be `api://{SERVER_CLIENT_ID}/mcp.access` |
| Server validates wrong audience | `401` from MCP server | Check server `AZURE_CLIENT_ID` / audience config and token `aud` |
| `resource` param sent to `/authorize` | `AADSTS901002` | FastMCP / VS Code is sending `resource`; remove it or treat as client bug |

---

## 5. Test client update

`client/test_client.py` must:
- remove any dependency on DCR
- use the resource app ID (`AZURE_CLIENT_ID` / `SERVER_CLIENT_ID`) to build the scope, and use `TEST_CLIENT_ID` or VS Code's client ID as the **public client**
- run the direct flow: **PKCE auth code → token exchange → MCP `hello_world` call**
- print token claims so QA can verify `Name` / `UPN` / `OID`
- tolerate `hello_world` vs `hello` naming while Naomi finishes server changes

### QA acceptance gate

Sign off only when **all** of the following are true:
1. Well-known metadata points directly to Entra
2. No DCR request is used anywhere in the flow
3. VS Code authorize request uses `scope=api://{SERVER_CLIENT_ID}/mcp.access`
4. VS Code authorize request does **not** include `resource=`
5. Token exchange succeeds
6. MCP tool call succeeds with `200`
7. Response or printed claims shows `name`, `preferred_username`/`upn`, and `oid`
