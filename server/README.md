# FastMCP RS-mode OAuth server

## Prerequisites

- [uv](https://docs.astral.sh/uv/) — `curl -LsSf https://astral.sh/uv/install.sh | sh`
- Python 3.12+

## Install

```bash
cd server && uv sync
```

## Configure

Copy `.env.example` to `.env` and fill in the Entra tenant, app/client ID, audience, and public host name. Set `RESOURCE_APP_ID` when Entra emits the app GUID in the `aud` claim instead of the identifier URI.

## Run

```bash
# Option 1 — uv run (recommended)
cd server && uv run python server.py

# Option 2 — uvicorn via uv
cd server && uv run uvicorn server:app --host 0.0.0.0 --port 8080

# Option 3 — via Makefile (from repo root)
make dev
```

## How it works

The MCP endpoint acts as an OAuth 2.0 protected resource, not as an authorization server. Clients discover Entra through `/.well-known/oauth-protected-resource`, obtain tokens directly from Entra, and send Bearer tokens to this server. The server validates each JWT locally against Entra's JWKS before FastMCP handles the request.

## Test

```bash
curl -H "Authorization: Bearer <token>" http://localhost:8080/mcp
```

## Azure App Service Deployment

Set the App Service startup command to:

```
bash startup.sh
```

`startup.sh` runs:
```bash
uv run uvicorn server:app --host 0.0.0.0 --port ${PORT:-8080}
```

The `PORT` environment variable is injected automatically by App Service.

Alternatively, after installing the package with `uv sync`, the console script entry point can be used:
```
cloud-helper-fastmcp
```

This calls `server.main()` which runs uvicorn using the `PORT` env var (default 8000).

## Dependency management

This project uses UV. Key files:
- `pyproject.toml` — canonical dependency spec
- `uv.lock` — pinned lockfile (committed to source control)
- `requirements.txt` — **deprecated** pip fallback, kept for emergency use only

To update dependencies:
```bash
cd server && uv add <package>   # adds and re-locks
cd server && uv lock --upgrade  # upgrades all within constraints
```
