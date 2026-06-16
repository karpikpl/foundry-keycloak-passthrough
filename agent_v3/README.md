# agent_v3 — shared agent + per-user token via structured inputs

A Foundry agent that uses the **native MCP tool** with **per-user
authorization injected at request time**, while keeping a single shared
agent definition for all users.

> Reference docs:
> - [Customize Agent Behavior at Runtime with Structured Inputs](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/structured-inputs?view=foundry&pivots=python)
> - [Use Remote MCP servers as a tool](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/tools/model-context-protocol)

## How this differs from the other variants

| Variant   | Token storage in Foundry | One agent shared by users? | OAuth flow                |
| --------- | ------------------------ | -------------------------- | ------------------------- |
| agent_v2  | Yes (apihub holds refresh token) | Yes              | Foundry-managed (OIP / project_connection_id) |
| **agent_v3 (this)** | **No (placeholder only)** | **Yes**                    | **Local PKCE; token passed per request** |
| agent_v4  | n/a (design only)        | Yes                        | Local PKCE; tool calls bridged client-side |

## Why structured inputs, not Identity Passthrough

Foundry's standard pattern for per-user MCP auth is `project_connection_id`
(a Foundry RemoteTool connection that performs OAuth on behalf of the user
and stores their refresh token). That works, but it does mean Foundry
holds a long-lived credential.

Structured inputs let us avoid that entirely. The doc lists
**MCP `headers` (values)** as a templatable property:

> | MCP | `headers` (values) | HTTP header values as key-value pairs |

So we declare the agent's MCP tool with a **placeholder** header value, and
each request supplies the real value via `structured_inputs`.

## What's stored on the agent definition

```python
mcp_tool = MCPTool(
    server_label="cloud_helper_mcp",
    server_url=os.environ["MCP_SERVER_URL"],
    headers={"Authorization": "{{userToken}}"},   # placeholder only
    require_approval="always",
)

PromptAgentDefinition(
    model="gpt-4o",
    instructions="...",
    tools=[mcp_tool],
    structured_inputs={
        "userToken": StructuredInputDefinition(
            description="Per-user Keycloak access token forwarded to the MCP server.",
            required=True,
            schema={"type": "string"},
        ),
    },
)
```

The agent definition itself is **persona + tool schema + placeholder**. No
real credential is ever persisted on Foundry.

## What's sent on every request

```python
response = await openai.responses.create(
    extra_body={
        "agent_reference": {"name": agent_name, "type": "agent_reference"},
        "structured_inputs": {"userToken": f"Bearer {access_token}"},
    },
    input=prompt,
)
```

Foundry substitutes `{{userToken}}` in the MCP tool's `Authorization`
header with the value the caller supplied for that single request, then
calls the MCP server. The substituted value lives only for the lifetime
of that HTTP request — Foundry does not persist it on the agent or in any
connector.

### Important Foundry policy gotcha

Sensitive headers (`Authorization`, etc.) are **only allowed if their
value is a single placeholder**. Mixing literal text with the template
triggers:

```
Headers that can include sensitive information are not allowed in the
headers property for MCP tools. Use project_connection_id instead.
```

That's why the value is `"{{userToken}}"` and **not** `"Bearer {{userToken}}"`.
We include the `Bearer ` prefix in the structured-input value at runtime
instead.

## Per-user token acquisition (local PKCE)

`agent.py` performs the OAuth code-flow + PKCE locally against Keycloak
(reusing the pattern from `client/test_client.py`):

  1. Discover Keycloak realm endpoints.
  2. Pop a browser → `authorization_endpoint` with PKCE + a loopback
     redirect to `http://127.0.0.1:55899/callback`.
  3. Receive the code, exchange it at `token_endpoint` (PKCE verifier +
     confidential-client secret).
  4. Inject the resulting access token into the next `responses.create()`
     call as `structured_inputs.userToken = "Bearer <token>"`.

`--idp-hint entra` skips Keycloak's local-login screen and federates the
user directly to Microsoft Entra ID (the realm's broker IdP).

## Run it

```bash
cd agent_v3
cp .env.example .env       # edit values, or run `azd deploy` to populate
uv sync
uv run agent.py --idp-hint entra
```

To prove isolation: have a second Entra user run the same command on
another machine. Both sessions hit the same `cloud-helper-agent-v3`
definition; each gets their own `whoami` answer because each call carries
only its own caller's token.

## Environment variables

| Var                | Purpose                                    |
| ------------------ | ------------------------------------------ |
| `FOUNDRY_ENDPOINT` | `https://<account>.cognitiveservices.azure.com/api/projects/<project>` |
| `MCP_SERVER_URL`   | MCP server URL (`https://<webapp>/mcp`)    |
| `KEYCLOAK_BASE_URL`| Keycloak host                              |
| `KEYCLOAK_REALM`   | Realm name (default `mcp-demo`)            |
| `CLIENT_ID`        | Keycloak client (default `mcp-server`)     |
| `CLIENT_SECRET`    | Keycloak `mcp-server` client secret        |
| `OAUTH_SCOPE`      | Default `openid profile email mcp.access`  |
| `CALLBACK_PORT`    | Loopback port (default 55899) — must match the redirect URI registered on the Keycloak client |
| `AGENT_MODEL`      | Model deployment (default `gpt-4o`)        |
| `AGENT_NAME`       | Shared agent name (default `cloud-helper-agent-v3`) |
| `IDP_HINT`         | Optional `kc_idp_hint` (e.g. `entra`)      |

## Limitations / open questions

- **Token expiry mid-conversation**: Keycloak access tokens default to 5 min
  in this realm. The current code does one `responses.create()` cycle, so
  short tokens are fine; longer conversations would need a refresh hook.
- **No refresh-token storage**: by design — refresh tokens never reach
  Foundry. Long-lived sessions need to either (a) re-PKCE in the local
  process when expiry approaches, or (b) request `offline_access` from
  Keycloak and persist the refresh token client-side.
- **Approval UI**: `require_approval="always"` shows the standard MCP
  approval prompt for every tool call. Auto-approval is implemented in
  `agent.py` for headless runs.
