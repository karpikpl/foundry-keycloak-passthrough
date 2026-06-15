# OAuth PKCE Flow — Test Cases

**Project:** mcp-oauth (Azure Web App: `<your-app>`)  
**Author:** Drummer (Tester / QA)  
**Created:** 2026-05-08T17:43:37Z  
**Status:** Ready for execution — Actual results and Pass/Fail to be filled during test run

---

## Environment Setup

```
MCP_SERVER_BASE_URL=https://<your-app>.azurewebsites.net   # or localhost for local testing
WELL_KNOWN_URL=$MCP_SERVER_BASE_URL/.well-known/oauth-authorization-server
REGISTER_URL=$MCP_SERVER_BASE_URL/register
TOKEN_URL=$MCP_SERVER_BASE_URL/token
AUTHORIZE_URL=$MCP_SERVER_BASE_URL/authorize
```

PKCE test values (deterministic for reproducibility):

```bash
# Generate test PKCE pair
CODE_VERIFIER="dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
CODE_CHALLENGE="E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
# Challenge method: S256 (SHA-256 of verifier, base64url-encoded)
```

---

## TC-01 — Full OAuth PKCE Flow Completes (Happy Path)

**Name:** Full OAuth PKCE flow — client POSTs to /token after receiving auth code  
**Type:** Happy path  
**Priority:** P0

### Preconditions
- MCP server is running and reachable at `$MCP_SERVER_BASE_URL`
- A valid Entra app registration exists with redirect URIs registered
- Tester has browser access to complete Entra login interactively
- `$CODE_VERIFIER` and `$CODE_CHALLENGE` defined as above

### Steps

1. **Verify discovery endpoint**
   ```bash
   curl -s $WELL_KNOWN_URL | jq .
   ```
   → Capture `authorization_endpoint`, `token_endpoint`, `registration_endpoint`

2. **Register a client dynamically**
   ```bash
   curl -s -X POST $REGISTER_URL \
     -H "Content-Type: application/json" \
     -d '{"redirect_uris":["http://localhost:8400/"],"client_name":"drummer-test-client"}' | jq .
   ```
   → Capture `client_id` as `$CLIENT_ID`

3. **Initiate authorization (PKCE)**
   ```bash
   curl -v "$AUTHORIZE_URL?response_type=code\
   &client_id=$CLIENT_ID\
   &redirect_uri=http://localhost:8400/\
   &code_challenge=$CODE_CHALLENGE\
   &code_challenge_method=S256\
   &state=test-state-01" 2>&1 | grep -E "Location:|HTTP/"
   ```
   → Server responds `302`. Follow the redirect URL in a browser.

4. **Complete Entra login in browser**  
   → Entra redirects back to `http://localhost:8400/?code=<AUTH_CODE>&state=test-state-01`  
   → Capture `<AUTH_CODE>` as `$AUTH_CODE`

5. **Exchange code for token**
   ```bash
   curl -s -X POST $TOKEN_URL \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=authorization_code\
   &code=$AUTH_CODE\
   &redirect_uri=http://localhost:8400/\
   &client_id=$CLIENT_ID\
   &code_verifier=$CODE_VERIFIER" | jq .
   ```

### Expected Result
- Step 1: `200 OK`, JSON body includes `authorization_endpoint`, `token_endpoint`, `registration_endpoint`, and `redirect_uris`
- Step 2: `201` or `200`, body includes `client_id`
- Step 3: `302` redirect to Entra login URL
- Step 4: Browser shows "Sign-in successful!" and redirects back with `code` and `state`
- Step 5: `200 OK`, body includes `access_token`, `token_type`, and optionally `refresh_token`

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## TC-02 — Reproduce: Client Never Calls /token (The Known Bug)

**Name:** Reproduce — auth code received at callback URI, client never calls /token  
**Type:** Bug reproduction (blocking)  
**Priority:** P0 — **Must reproduce before any fix is attempted**

### Preconditions
- MCP server deployed as `<your-app>` (Azure Web App) with OAuth PKCE enabled
- VS Code with MCP extension OR Azure AI Foundry agent configured to connect to the MCP server
- Entra login can be completed in browser
- Server logs accessible (App Service log stream or local stdout)

### Steps

1. **Tail server logs** (open a separate terminal)
   ```bash
   # Azure App Service log stream
   az webapp log tail --name <your-app> --resource-group <your-resource-group>
   # OR for local: watch server stdout
   ```

2. **Connect client to MCP server**  
   - VS Code: Add MCP server entry pointing to `$MCP_SERVER_BASE_URL`  
   - OR: Trigger AI Foundry agent that targets your MCP server

3. **Observe the OAuth flow initiation**
   - Confirm `GET /.well-known/oauth-authorization-server` appears in logs → ✅
   - Confirm `POST /register` appears in logs → ✅
   - Confirm `GET /authorize` appears in logs → ✅

4. **Complete Entra login in browser**
   - Browser shows "Sign-in successful!" → ✅
   - Entra redirects to callback URI with `?code=...&state=...` → ✅

5. **Monitor for /token call**
   - Watch server logs for `POST /token` — wait at least 60 seconds
   - Observe client connection status

6. **Record the outcome**
   - Note: Does `POST /token` appear in logs?
   - Note: Does the client report a timeout or hang?
   - Note: Does the callback URI match registered redirect URIs exactly?

### Expected Result
`POST /token` appears in server logs within a few seconds of the callback redirect. Client connection completes successfully.

### Actual Result (per issue-report.md)
`POST /token` **never appears** in logs. Client hangs indefinitely. No error is surfaced to the user.

### Hypothesis to investigate
The callback URI (`http://127.0.0.1:<port>/`) does not match any registered redirect URI (`http://localhost` variants, `https://foundry.azure.com/`, `https://vscode.dev/redirect`). The client silently drops the code because it doesn't recognize the redirect. OR: the server's metadata (`/.well-known/...`) advertises a redirect URI that doesn't match what the client sends, causing it to abort silently.

### Pass/Fail
> ☐ Reproduced (bug confirmed) &nbsp; ☐ Not reproduced (investigate setup)

---

## TC-03 — Redirect URI Mismatch

**Name:** Client sends redirect URI not matching registered list  
**Type:** Security / negative  
**Priority:** P1

### Preconditions
- MCP server running
- Valid `$CLIENT_ID` obtained via `/register` (registered with `http://localhost:8400/`)

### Steps

1. **Initiate authorization with a mismatched redirect URI**
   ```bash
   curl -v "$AUTHORIZE_URL?response_type=code\
   &client_id=$CLIENT_ID\
   &redirect_uri=http://evil.example.com/callback\
   &code_challenge=$CODE_CHALLENGE\
   &code_challenge_method=S256\
   &state=test-state-03"
   ```

2. **Record the server response**

### Expected Result
Server returns `400 Bad Request` with `error=invalid_request` or `error=redirect_uri_mismatch`. The authorization flow does **not** proceed to Entra. No redirect to `evil.example.com`.

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## TC-04 — PKCE code_verifier Mismatch

**Name:** Verifier doesn't match the original code_challenge  
**Type:** Security / negative  
**Priority:** P1

### Preconditions
- MCP server running
- Valid `$CLIENT_ID` obtained
- A valid auth code `$AUTH_CODE` has been obtained by completing the full authorization flow (TC-01 steps 1–4) using `$CODE_CHALLENGE`

### Steps

1. **Attempt token exchange with wrong verifier**
   ```bash
   WRONG_VERIFIER="wrongverifierthatdoesnotmatchchallengeatall12345"

   curl -s -X POST $TOKEN_URL \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=authorization_code\
   &code=$AUTH_CODE\
   &redirect_uri=http://localhost:8400/\
   &client_id=$CLIENT_ID\
   &code_verifier=$WRONG_VERIFIER" | jq .
   ```

2. **Record the response body and HTTP status**

### Expected Result
`400 Bad Request` with `{"error":"invalid_grant","error_description":"PKCE verification failed"}` (or equivalent). No token issued.

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## TC-05 — Expired Authorization Code

**Name:** Try to exchange a stale auth code  
**Type:** Negative / timing  
**Priority:** P1

### Preconditions
- MCP server running
- Valid `$CLIENT_ID` and `$CODE_CHALLENGE` available
- Authorization code lifetime is known (typically 10 minutes for Entra; check server config)

### Steps

1. **Obtain a valid auth code** by completing the authorization flow (TC-01 steps 1–4). Note the time.

2. **Wait for the code to expire** (wait beyond the code lifetime — at minimum 11 minutes for Entra-issued codes, or however long the server's own code TTL is)

3. **Attempt token exchange with the expired code**
   ```bash
   curl -s -X POST $TOKEN_URL \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=authorization_code\
   &code=$AUTH_CODE\
   &redirect_uri=http://localhost:8400/\
   &client_id=$CLIENT_ID\
   &code_verifier=$CODE_VERIFIER" | jq .
   ```

4. **Record the response body and HTTP status**

### Expected Result
`400 Bad Request` with `{"error":"invalid_grant","error_description":"Authorization code expired"}` or equivalent. No token issued.

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## TC-06 — Missing State Parameter

**Name:** State not present in the authorization callback  
**Type:** Security / negative  
**Priority:** P1

### Preconditions
- MCP server running
- Valid `$CLIENT_ID` obtained

### Steps

1. **Initiate authorization without a state parameter**
   ```bash
   curl -v "$AUTHORIZE_URL?response_type=code\
   &client_id=$CLIENT_ID\
   &redirect_uri=http://localhost:8400/\
   &code_challenge=$CODE_CHALLENGE\
   &code_challenge_method=S256"
   # Note: no &state=...
   ```

2. **Observe server behavior**  
   - Does the server reject the request immediately?  
   - Does it still redirect to Entra?

3. **If redirected to Entra:** complete login and check whether the callback is accepted without `state`

4. **Record the response at each step**

### Expected Result
Server either: (a) rejects with `400 Bad Request` (`error=invalid_request`, state required), OR (b) accepts but the client must not bind the callback to a prior request — either way, the server must not issue a token without verifiable state. Preferred behavior: reject at step 1.

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## TC-07 — State Parameter Mismatch

**Name:** Callback state doesn't match the state sent in the authorization request  
**Type:** Security / CSRF protection  
**Priority:** P1

### Preconditions
- MCP server running
- A valid auth code has been obtained with `state=test-state-07` in the authorization request

### Steps

1. **Simulate a callback with tampered state**  
   _(This simulates what a client should do — reject mismatched state — and what the server should do if it validates state itself)_

   ```bash
   # Attempt to use the code but with a different state value in the URL
   # (Relevant if the server validates state on the callback endpoint)
   curl -v "http://localhost:8400/?code=$AUTH_CODE&state=TAMPERED_STATE"
   ```

2. **If the server exposes a callback endpoint directly**, test it:
   ```bash
   curl -v "$MCP_SERVER_BASE_URL/callback?code=$AUTH_CODE&state=TAMPERED_STATE"
   ```

3. **Then attempt the /token exchange with this code**
   ```bash
   curl -s -X POST $TOKEN_URL \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=authorization_code\
   &code=$AUTH_CODE\
   &redirect_uri=http://localhost:8400/\
   &client_id=$CLIENT_ID\
   &code_verifier=$CODE_VERIFIER" | jq .
   ```

4. **Record all responses**

### Expected Result
If the server validates `state` on the callback: `400` or `403` with `error=invalid_state`.  
If state validation is client-side only: the server issues a token but the conforming client must reject it. Document which model applies.  
No token should be usable when state is tampered.

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## TC-08 — /token Called with Wrong grant_type

**Name:** Token endpoint called with unsupported or wrong grant_type  
**Type:** Negative / error handling  
**Priority:** P2

### Preconditions
- MCP server running
- Valid `$CLIENT_ID` and `$AUTH_CODE` available

### Steps

1. **Call /token with `grant_type=implicit`**
   ```bash
   curl -s -X POST $TOKEN_URL \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=implicit\
   &code=$AUTH_CODE\
   &redirect_uri=http://localhost:8400/\
   &client_id=$CLIENT_ID" | jq .
   ```

2. **Call /token with `grant_type=client_credentials`**
   ```bash
   curl -s -X POST $TOKEN_URL \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=client_credentials\
   &client_id=$CLIENT_ID" | jq .
   ```

3. **Call /token with no grant_type**
   ```bash
   curl -s -X POST $TOKEN_URL \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "code=$AUTH_CODE\
   &redirect_uri=http://localhost:8400/\
   &client_id=$CLIENT_ID" | jq .
   ```

4. **Record all HTTP statuses and response bodies**

### Expected Result
All three calls return `400 Bad Request` with `{"error":"unsupported_grant_type"}` or `{"error":"invalid_request"}` as appropriate per RFC 6749 §5.2. No token issued.

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## TC-09 — VS Code Client Connects Successfully After Fix

**Name:** VS Code MCP client completes OAuth flow end-to-end  
**Type:** Integration / client verification  
**Priority:** P0 — **Required for sign-off**

### Preconditions
- Fix for the token exchange hang has been applied and deployed
- VS Code installed with MCP extension
- MCP server configured with `$MCP_SERVER_BASE_URL`
- Entra credentials available for browser login

### Steps

1. **Configure MCP server in VS Code**
   - Add server entry with URL: `$MCP_SERVER_BASE_URL`

2. **Initiate connection from VS Code**
   - Open MCP panel → connect to server
   - VS Code should open browser for Entra login

3. **Complete Entra login in browser**

4. **Observe VS Code MCP connection status**

5. **Verify server logs show the full flow**
   ```
   GET  /.well-known/oauth-authorization-server  → 200
   POST /register                                → 200/201
   GET  /authorize                               → 302
   POST /token                                   → 200   ← This must appear
   ```

6. **Verify client is connected and can call MCP tools**

### Expected Result
VS Code MCP connection status shows "Connected". `POST /token` appears in server logs. MCP tools are callable from VS Code.

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## TC-10 — AI Foundry Agent Connects Successfully After Fix

**Name:** Azure AI Foundry agent completes OAuth flow end-to-end  
**Type:** Integration / client verification  
**Priority:** P0 — **Required for sign-off**

### Preconditions
- Fix applied and deployed
- AI Foundry workspace `<your-foundry-workspace>` (RG: `<your-resource-group>`, subscription: `<your-subscription-name>`) configured to connect to your MCP server
- Entra credentials available

### Steps

1. **Navigate to AI Foundry agent configuration**
   - Confirm MCP server URL is set to `$MCP_SERVER_BASE_URL`

2. **Trigger agent connection to MCP server**

3. **Complete Entra browser login if prompted**

4. **Observe AI Foundry connection status**

5. **Verify server logs show full flow including `/token`**
   ```
   POST /token → 200   ← Must appear
   ```

6. **Test that the agent can invoke at least one MCP tool successfully**

### Expected Result
AI Foundry agent shows the MCP server as connected. `POST /token` appears in logs. Agent can invoke MCP tools without hanging or timing out.

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## TC-11 — /.well-known/oauth-authorization-server Returns Correct redirect_uris

**Name:** Discovery document advertises all expected redirect URIs  
**Type:** Conformance / metadata verification  
**Priority:** P1

### Preconditions
- MCP server running

### Steps

1. **Fetch the discovery document**
   ```bash
   curl -s $WELL_KNOWN_URL | jq .
   ```

2. **Check for presence of `redirect_uris` field** (note: this is an extension field — not all servers include it, but if present it must be accurate)

3. **Cross-check that the following URIs are reachable / registered on the Entra app:**
   - `https://foundry.azure.com/`
   - `https://vscode.dev/redirect`
   - `http://localhost` (with any port)

4. **Compare against what VS Code and AI Foundry clients actually send as `redirect_uri` in their authorization requests** (capture from server logs during TC-09 / TC-10)

### Expected Result
- `200 OK` with valid JSON
- Required fields present: `issuer`, `authorization_endpoint`, `token_endpoint`, `response_types_supported`, `code_challenge_methods_supported`
- `redirect_uris` (if present) matches the URIs registered on the Entra app
- No mismatch between what the discovery doc advertises and what Entra has registered

### Watch for
⚠️ If `redirect_uris` in the discovery doc lists `http://localhost` but clients send `http://127.0.0.1:<port>/`, this mismatch is a likely root cause of TC-02.

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## TC-12 — Dynamic Client Registration Returns client_id That Works in Subsequent Flow

**Name:** /register response client_id is accepted throughout the full PKCE flow  
**Type:** Integration / conformance  
**Priority:** P1

### Preconditions
- MCP server running
- No pre-registered client — test starts from scratch

### Steps

1. **Register a new client**
   ```bash
   REGISTER_RESPONSE=$(curl -s -X POST $REGISTER_URL \
     -H "Content-Type: application/json" \
     -d '{"redirect_uris":["http://localhost:8400/"],"client_name":"drummer-tc12-client"}')
   echo $REGISTER_RESPONSE | jq .
   CLIENT_ID=$(echo $REGISTER_RESPONSE | jq -r .client_id)
   echo "Got client_id: $CLIENT_ID"
   ```

2. **Use the returned `client_id` in an authorization request**
   ```bash
   curl -v "$AUTHORIZE_URL?response_type=code\
   &client_id=$CLIENT_ID\
   &redirect_uri=http://localhost:8400/\
   &code_challenge=$CODE_CHALLENGE\
   &code_challenge_method=S256\
   &state=test-state-12"
   ```

3. **Complete Entra login in browser**, capture `$AUTH_CODE`

4. **Exchange code for token using the same `client_id`**
   ```bash
   curl -s -X POST $TOKEN_URL \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=authorization_code\
   &code=$AUTH_CODE\
   &redirect_uri=http://localhost:8400/\
   &client_id=$CLIENT_ID\
   &code_verifier=$CODE_VERIFIER" | jq .
   ```

5. **Repeat with a second freshly registered client** to confirm registration is not a one-shot operation

### Expected Result
- Step 1: `client_id` returned and non-empty
- Step 2: Server accepts `client_id`, returns `302` to Entra
- Step 4: `200 OK`, `access_token` returned
- Step 5: Second client also works — registration is repeatable

### Actual Result
> _To be filled during execution_

### Pass/Fail
> ☐ Pass &nbsp; ☐ Fail

---

## Test Execution Summary

| ID    | Name                                              | Priority | Pass/Fail |
|-------|---------------------------------------------------|----------|-----------|
| TC-01 | Full PKCE flow — happy path                       | P0       |           |
| TC-02 | Reproduce: client never calls /token              | P0       |           |
| TC-03 | Redirect URI mismatch                             | P1       |           |
| TC-04 | PKCE code_verifier mismatch                       | P1       |           |
| TC-05 | Expired authorization code                        | P1       |           |
| TC-06 | Missing state parameter                           | P1       |           |
| TC-07 | State parameter mismatch                          | P1       |           |
| TC-08 | /token called with wrong grant_type               | P2       |           |
| TC-09 | VS Code connects successfully after fix           | P0       |           |
| TC-10 | AI Foundry connects successfully after fix        | P0       |           |
| TC-11 | /.well-known returns correct redirect_uris        | P1       |           |
| TC-12 | Dynamic registration client_id works end-to-end   | P1       |           |

## Sign-off Criteria

- **TC-02 must reproduce** before any fix is attempted
- **TC-01, TC-09, TC-10 must all Pass** before the fix is considered done
- **TC-03, TC-04, TC-05, TC-07 must all Pass** — no security regressions
- Any Fail blocks shipment. No partial credit.
