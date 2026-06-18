# agent_v5 — Foundry agent against Leena.ai MCP

Same pattern as [`agent_v3`](../agent_v3/README.md): one shared Foundry
agent definition, per-user bearer token injected at request time via
[Foundry **structured inputs**](https://learn.microsoft.com/azure/foundry/agents/how-to/structured-inputs).

The only difference is the identity provider and MCP target:

| | agent_v3 | **agent_v5** |
|---|---|---|
| IdP | Keycloak (federated to Entra) | **Leena.ai OAuth** |
| MCP server | Self-hosted (`*.azurewebsites.net/mcp`) | **`https://sandbox-aic.leena.ai/mcp/`** |
| OAuth endpoints | Discovered via OIDC `/.well-known` | Hardcoded: `https://sandbox-chat.leena.ai/api/oauth/{authorize,token}` |
| Foundry agent | One shared definition + structured input | Same |
| Sensitive-header policy | `Authorization: {{userToken}}` (pure placeholder) | Same |

## How it works

1. **Local OAuth login.** The CLI runs an authorization-code flow
   (PKCE on by default) against Leena, captures the code on
   `http://127.0.0.1:8765/callback`, and exchanges it for an access
   token at `…/api/oauth/token`. The token never leaves the local
   process except as the templated value below.
2. **Shared Foundry agent.** A single named agent
   (`cloud-helper-agent-v5`) is created/updated with an MCP tool whose
   `Authorization` header is just the placeholder `"{{userToken}}"`.
3. **Per-request injection.** Each `responses.create()` call passes
   `structured_inputs={"userToken": "Bearer <access_token>"}`. Foundry
   substitutes the value for that one HTTP call to Leena's MCP server
   and forgets it.

This keeps the agent definition free of any user secret, and prevents
two users from ever sharing a token — each request carries only its
own caller's bearer in flight.

## Setup

1. Register an OAuth client in Leena with redirect URI
   `http://127.0.0.1:8765/callback` (port configurable via
   `CALLBACK_PORT`).
2. Copy `.env.example` → `.env` and fill in `CLIENT_SECRET`,
   `FOUNDRY_ENDPOINT`, and any scopes Leena expects.
3. Run:
   ```bash
   uv sync
   uv run agent.py --prompt "What can you do?"
   ```
   On first run a browser tab opens to Leena's consent screen; after
   you sign in, control returns to the CLI and the agent runs.

## Notes / known gotchas

- **Sensitive headers.** Foundry rejects MCP tool headers that mix
  literal text with handlebar templates for sensitive header names
  (`Authorization`, etc). The value must be a *pure* placeholder
  (`"{{userToken}}"`); the literal `Bearer ` prefix lives in the
  runtime value of the structured input.
- **PKCE.** Enabled by default. If Leena's OAuth server doesn't accept
  `code_challenge`, set `USE_PKCE=false` in `.env`.
- **Scopes.** Left empty by default — set `OAUTH_SCOPE=...` if Leena
  requires explicit scopes.
- **Token type.** If Leena returns an opaque (non-JWT) access token,
  the claim dump is skipped; this does not affect the flow.
