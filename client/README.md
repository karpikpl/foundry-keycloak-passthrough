# MCP direct-Entra PKCE test client

This client validates the direct-Entra pattern end-to-end:

1. Discovers RFC 9728 protected resource metadata from the MCP server
2. Uses a **pre-registered** public client ID (no Dynamic Client Registration)
3. Runs OAuth authorization-code + PKCE against Entra
4. Exchanges the auth code for an access token
5. Reconnects to the MCP `/mcp` endpoint with `Authorization: Bearer ...`
6. Calls `hello`/`hello_world` and prints token claims for verification

## Default target

The client now defaults to the fixed staging slot:

- `https://<your-app>.azurewebsites.net/mcp` ← fixed

Use `--url` to point at another slot, for example the repro slot:

- `https://<your-app>.azurewebsites.net/mcp` ← repro

## How to run

```bash
cd client
uv run test_client.py direct
```

Optional overrides:

```bash
uv run test_client.py direct \
  --url https://<your-app>.azurewebsites.net/mcp \
  --client-id <pre-registered-public-client-id>
```

Notes:
- The client uses an interactive browser + localhost loopback callback for PKCE sign-in.
- `--client-id` falls back to `TEST_CLIENT_ID`, then to VS Code's public client ID (`aebc6443-996d-45c2-90f0-388ff96faa56`).
- `--scope` defaults to the first `scopes_supported` entry in protected resource metadata.
- If metadata does not publish scopes, pass `--scope` or `--server-client-id`.

## Expected result

```text
✅ Direct Entra flow succeeded: tools/list returned ...
--- Token claims ---
  name       ...
  upn        ...
  oid        ...
```

If Entra or the MCP server is misconfigured, the client prints a targeted error that points at metadata discovery, Entra auth, or Bearer-token validation.
