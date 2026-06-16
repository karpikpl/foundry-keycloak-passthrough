# MCP OAuth — Keycloak Authorization Server with Entra Federation

Demonstrates a [FastMCP](https://github.com/jlowin/fastmcp) server protected by
**Keycloak as the OAuth 2.0 authorization server**, with **Microsoft Entra ID
federated upstream** as an OIDC identity provider (Keycloak IdP broker). The
MCP server only ever validates Keycloak-issued tokens; Entra users still sign
in with their real corporate identity, but Keycloak is the issuer of record.

Ported from
[`foundry-entra-passthrough`](https://github.com/karpikpl/foundry-entra-passthrough)
— the App Service, Foundry, networking, and Bicep scaffolding are reused
verbatim; only the auth server changes.

## What this shows

| Client | Auth Mechanism |
|--------|---------------|
| VS Code MCP client | [RFC 9728 Protected Resource Metadata](https://datatracker.ietf.org/doc/html/rfc9728) → Keycloak realm endpoints |
| `test_client.py` | OAuth 2.0 PKCE flow against the Keycloak realm |
| `agent_v2/` (Azure AI Foundry) | Foundry MCP connection configured with Keycloak's auth/token URLs and `mcp-server` client credentials |

In every case the MCP server receives a Keycloak access token. If the user
logged in through the Entra IdP broker, the token's `sub`/`email`/`name`
claims map back to the original Entra identity (Keycloak's default `IMPORT`
sync mode populates them from the upstream id_token).

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                       Microsoft Entra ID                             │
│   App reg: keycloak-broker-<env>  (used only by Keycloak as upstream)│
└─────────────────────────────────┬────────────────────────────────────┘
                                  │ OIDC (authorization code)
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Keycloak (Azure Container Apps)                                     │
│  Realm: mcp-demo                                                     │
│  Backed by Azure Database for PostgreSQL (Burstable B1ms)            │
│  Issues access_tokens with aud=mcp-server                            │
└─────────────────────────────────┬────────────────────────────────────┘
                                  │ OAuth 2.0 PKCE  /  Identity Passthrough
       ┌──────────────────────────┼──────────────────────────┐
       │                          │                          │
  ┌────▼─────┐             ┌──────▼──────┐           ┌──────▼─────────┐
  │ VS Code  │             │ test_client │           │  AI Foundry    │
  │ (RFC9728)│             │  (PKCE)     │           │  Agent (passth.)│
  └────┬─────┘             └──────┬──────┘           └──────┬─────────┘
       └──────────────────────────┴──────────────────────────┘
                                  │ Bearer token (Keycloak-issued)
                                  ▼
                  ┌────────────────────────────────┐
                  │ FastMCP server (App Service)   │
                  │ JWT verifier — Keycloak JWKS   │
                  │ tools: whoami, hello           │
                  └────────────────────────────────┘
```

## Why federation rather than Keycloak-local users

Entra remains the IdP of record for human identity, MFA, and lifecycle. Apps
that need an extra layer of OAuth scope/role modeling (or that need to also
accept non-Entra users) can delegate that to Keycloak without re-inventing
session management or user provisioning.

## Reused vs. new

| Reused unchanged | New / changed |
|------------------|---------------|
| `infra/modules/networking/*` (VNet, PE, DNS) | `infra/modules/data/postgres.bicep` |
| `infra/modules/monitor/*`, `iam/*` | `infra/modules/apps/keycloak-aca.bicep` |
| `infra/modules/ai/*` (Foundry account + project) | `infra/modules/appRegistrations.bicep` (rewritten — broker app only) |
| `infra/modules/appService.bicep` (MCP host) | `server/config.py` (Keycloak issuer/JWKS) |
| `infra/modules/apps/apps-private-link.bicep` | `scripts/postprovision.sh` (realm + IdP + client setup) |
| `client/`, `agent_v2/`, `tests/`             | `azure.yaml` postprovision/postdeploy |

## Deploy

```bash
azd auth login
azd env new keycloak-dev

# Required secrets — pick strong values, store via azd's encrypted env state.
azd env set KEYCLOAK_ADMIN_PASSWORD "$(openssl rand -base64 24)"
azd env set POSTGRES_ADMIN_PASSWORD "$(openssl rand -base64 24)"

azd up
```

`azd up` will:
1. Provision VNet, Log Analytics, AI Foundry, App Service, Postgres, Keycloak ACA, and a placeholder Entra app registration.
2. Run `scripts/postprovision.sh`:
   - Wait for Keycloak `/realms/master` to respond.
   - Create the `mcp-demo` realm.
   - `az ad app credential reset` on the broker app and add the realm callback to its redirect URIs.
   - Configure the Entra OIDC IdP inside the Keycloak realm.
   - Create the confidential client `mcp-server` (PKCE + secret, audience mapper).
   - Update the App Service settings (`KEYCLOAK_BASE_URL`, `KEYCLOAK_REALM`, `CLIENT_ID`, `AUDIENCE`).
   - Create the Foundry MCP RemoteTool connection pointing at the Keycloak realm endpoints and feed Foundry's returned redirect URL back into the Keycloak client.
3. Deploy the FastMCP server to App Service and run the postdeploy hook to write `client/.env` and `agent_v2/.env`.

## Local testing

```bash
cd client && uv sync && uv run test_client.py login
```

```bash
cd agent_v2 && uv sync && uv run agent.py --prompt "Who am I? Call the whoami tool."
```

The first browser flow takes you to Keycloak's login page, which shows a
"Microsoft Entra ID" button (the broker). Click it to sign in with your Entra
account; Keycloak then mints its own token and the MCP server validates it.

## References

- [Keycloak Identity Brokering](https://www.keycloak.org/docs/latest/server_admin/#_identity_broker)
- [FastMCP](https://github.com/jlowin/fastmcp)
- [RFC 9728 — OAuth 2.0 Protected Resource Metadata](https://datatracker.ietf.org/doc/html/rfc9728)
- Original repo: [`foundry-entra-passthrough`](https://github.com/karpikpl/foundry-entra-passthrough)

## License

MIT
