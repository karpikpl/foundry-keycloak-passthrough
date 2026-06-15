from __future__ import annotations

import base64
import json
import os
import webbrowser
from pathlib import Path
from typing import Any, TypedDict
from urllib.parse import urlparse

import anyio
import click
import httpx
from dotenv import load_dotenv
from fastmcp import Client
from fastmcp.client.auth import BearerAuth, OAuth

ENV_FILE = Path(__file__).with_name(".env")
load_dotenv(ENV_FILE)

DEFAULT_SERVER_URL = "https://<your-app>.azurewebsites.net/mcp"
VSCODE_CLIENT_ID = "aebc6443-996d-45c2-90f0-388ff96faa56"
HELLO_TOOL_CANDIDATES = ("hello_world", "hello")


class ProtectedResourceMetadata(TypedDict):
    prm_url: str
    authorization_server: str
    scope: str | None
    resource: str


def _first_env(*names: str) -> str | None:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


def _normalize_server_url(server_url: str) -> str:
    if not server_url.startswith("http"):
        server_url = "https://" + server_url
    parsed = urlparse(server_url)
    if not parsed.path or parsed.path == "/":
        return server_url.rstrip("/") + "/mcp"
    return server_url.rstrip("/")


def _protected_resource_candidates(server_url: str) -> list[str]:
    base_url = server_url.removesuffix("/mcp")
    return [
        base_url + "/.well-known/oauth-protected-resource",
        base_url + "/.well-known/oauth-protected-resource/mcp",
    ]


def _discover_protected_resource(server_url: str) -> ProtectedResourceMetadata:
    last_error: Exception | None = None
    for prm_url in _protected_resource_candidates(server_url):
        try:
            response = httpx.get(
                prm_url,
                headers={"Accept": "application/json"},
                timeout=10.0,
                follow_redirects=True,
            )
            if response.status_code == 404:
                continue
            response.raise_for_status()
            payload = response.json()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip()
            raise click.ClickException(
                f"Protected resource metadata discovery failed at {prm_url} "
                f"with HTTP {exc.response.status_code}: {body or exc}"
            ) from exc
        except (httpx.HTTPError, ValueError) as exc:
            last_error = exc
            continue

        authorization_servers = payload.get("authorization_servers")
        if not isinstance(authorization_servers, list) or not authorization_servers:
            raise click.ClickException(
                f"Protected resource metadata at {prm_url} did not include authorization_servers."
            )

        scopes_supported = payload.get("scopes_supported")
        discovered_scope = None
        if isinstance(scopes_supported, list) and scopes_supported:
            discovered_scope = str(scopes_supported[0])

        resource = payload.get("resource")
        if not isinstance(resource, str) or not resource:
            resource = server_url

        return {
            "prm_url": prm_url,
            "authorization_server": str(authorization_servers[0]),
            "scope": discovered_scope,
            "resource": resource,
        }

    if last_error:
        raise click.ClickException(
            f"Could not fetch protected resource metadata for {server_url}: {last_error}"
        ) from last_error
    raise click.ClickException(
        f"Could not find RFC 9728 protected resource metadata for {server_url}."
    )


def _resolve_scope(
    explicit_scope: str | None,
    discovered_scope: str | None,
    server_client_id: str | None,
) -> str:
    if explicit_scope:
        return explicit_scope
    if discovered_scope:
        return discovered_scope

    resolved_server_client_id = server_client_id or _first_env(
        "AZURE_CLIENT_ID",
        "SERVER_CLIENT_ID",
        "CLIENT_ID",
        "ENTRA_APP_CLIENT_ID",
    )
    if resolved_server_client_id:
        return f"api://{resolved_server_client_id}/mcp.access"

    raise click.ClickException(
        "Could not determine the scope to request. Pass --scope or --server-client-id, "
        "or configure the server to publish scopes_supported in its protected resource metadata."
    )


def _resolve_config(
    server_url: str | None,
    client_id: str | None,
    server_client_id: str | None,
    scope: str | None,
) -> dict[str, str]:
    resolved_server_url = _normalize_server_url(
        server_url
        or _first_env(
            "SERVER_URL",
        )
        or DEFAULT_SERVER_URL
    )
    prm = _discover_protected_resource(resolved_server_url)
    resolved_scope = _resolve_scope(
        explicit_scope=scope or _first_env("MCP_SCOPE"),
        discovered_scope=prm["scope"],
        server_client_id=server_client_id,
    )
    resolved_client_id = (
        client_id
        or _first_env("TEST_CLIENT_ID", "ENTRA_APP_CLIENT_ID")
        or VSCODE_CLIENT_ID
    )

    return {
        "server_url": resolved_server_url,
        "client_id": resolved_client_id,
        "scope": resolved_scope,
        "prm_url": prm["prm_url"],
        "authorization_server": prm["authorization_server"],
        "resource": prm["resource"],
    }


def _decode_jwt_payload(token: str) -> dict[str, Any]:
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)
        return json.loads(base64.urlsafe_b64decode(payload_b64))
    except Exception:
        return {}


class _OAuth(OAuth):
    """OAuth with terminal-friendly URL output and optional browser launch."""

    def __init__(self, *args: Any, open_browser: bool = True, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._open_browser = open_browser

    async def redirect_handler(self, authorization_url: str) -> None:
        click.echo("\n" + "─" * 60)
        click.echo("Open this URL to authenticate:")
        click.echo(authorization_url)
        click.echo("─" * 60 + "\n")
        if self._open_browser:
            webbrowser.open(authorization_url)


async def _call_hello_tool(
    client: Client, tool_names: list[str]
) -> tuple[str | None, str | None]:
    for tool_name in HELLO_TOOL_CANDIDATES:
        if tool_name in tool_names:
            call_result = await client.call_tool(tool_name, {"name": "World"})
            result_text = call_result.content[0].text if call_result.content else None
            return tool_name, result_text
    return None, None


async def _fetch_access_token(
    config: dict[str, str], open_browser: bool
) -> tuple[str, dict[str, Any]]:
    # This uses an interactive browser + localhost loopback callback. That is
    # expected for local testing and mirrors the standard PKCE desktop-app flow.
    oauth = _OAuth(
        mcp_url=config["server_url"],
        scopes=[config["scope"]],
        client_name="MCP Test Client",
        client_id=config["client_id"],
        open_browser=open_browser,
    )

    async with Client(config["server_url"], auth=oauth) as client:
        await client.list_tools()

    tokens = await oauth.token_storage_adapter.get_tokens()
    if not tokens or not tokens.access_token:
        raise RuntimeError(
            "Entra sign-in completed, but the FastMCP OAuth helper did not store an access token."
        )

    claims = _decode_jwt_payload(tokens.access_token)
    if tokens.scope and "scp" not in claims:
        claims["scp"] = tokens.scope
    return tokens.access_token, claims


async def _run_flow(
    config: dict[str, str], open_browser: bool
) -> tuple[list[str], str | None, str | None, dict[str, Any]]:
    access_token, claims = await _fetch_access_token(config, open_browser)

    async with Client(config["server_url"], auth=BearerAuth(access_token)) as client:
        tools = await client.list_tools()
        tool_names = [tool.name for tool in tools]
        called_tool, tool_result = await _call_hello_tool(client, tool_names)
        return tool_names, called_tool, tool_result, claims


def _claim_value(claims: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        value = claims.get(key)
        if value not in (None, "", []):
            return value
    return "<missing>"


def _format_claims(claims: dict[str, Any]) -> str:
    if not claims:
        return "No access token claims captured."

    rows = [
        ("aud", _claim_value(claims, "aud")),
        ("azp/appid", _claim_value(claims, "azp", "appid")),
        ("scope", _claim_value(claims, "scp")),
        ("name", _claim_value(claims, "name")),
        ("upn", _claim_value(claims, "preferred_username", "upn")),
        ("oid", _claim_value(claims, "oid")),
        ("tid", _claim_value(claims, "tid")),
    ]
    return "\n".join(f"  {label:10} {value}" for label, value in rows)


def _raise_auth_error(exc: Exception, config: dict[str, str]) -> None:
    message = str(exc).strip() or exc.__class__.__name__
    hints: list[str] = []
    lower_message = message.lower()

    if "aadsts" in lower_message or "access_denied" in lower_message:
        hints.append("Entra rejected the authorization or token request; inspect the AADSTS code in the browser or terminal output.")
    if "redirect" in lower_message:
        hints.append("Verify the public client app registration allows the localhost loopback redirect URI used by desktop PKCE flows.")
    if any(term in lower_message for term in ("401", "403", "scope", "audience")):
        hints.append("Verify the app registration exposes api://<app-id>/mcp.access and that the requested scope matches.")

    hint_text = ""
    if hints:
        hint_text = "\nHints:\n- " + "\n- ".join(hints)

    raise click.ClickException(
        f"Authentication failed for {config['server_url']} via {config['authorization_server']}: {message}{hint_text}"
    ) from exc


def run_flow(
    server_url: str | None,
    client_id: str | None,
    server_client_id: str | None,
    scope: str | None,
    open_browser: bool,
) -> None:
    config = _resolve_config(server_url, client_id, server_client_id, scope)

    click.echo(f"Server URL: {config['server_url']}")
    click.echo(f"Protected resource metadata: {config['prm_url']}")
    click.echo(f"Authorization server: {config['authorization_server']}")
    click.echo(f"Resource: {config['resource']}")
    click.echo(f"Public client ID: {config['client_id']}")
    click.echo(f"Requested scope: {config['scope']}")

    try:
        tool_names, called_tool, tool_result, claims = anyio.run(
            _run_flow, config, open_browser
        )
    except Exception as exc:
        _raise_auth_error(exc, config)

    click.echo(
        f"\n✅ Auth flow succeeded: tools/list returned {len(tool_names)} tool(s): {tool_names}"
    )
    click.echo("\n--- Token claims ---")
    click.echo(_format_claims(claims))
    click.echo("--------------------")

    if called_tool and tool_result:
        click.echo(f"\n--- Tool result ({called_tool}) ---")
        click.echo(tool_result)
        click.echo("-------------------------------")
    else:
        click.echo(
            "\n⚠️  No hello tool was exposed. The auth flow still succeeded, but "
            "the server did not publish hello_world/hello for the end-to-end check."
        )


COMMON_OPTIONS = [
    click.option(
        "--url",
        "server_url",
        "--server-url",
        help=(
            "MCP endpoint URL. Defaults to: "
            f"{DEFAULT_SERVER_URL}"
        ),
    ),
    click.option(
        "--client-id",
        help=(
            "Pre-registered public client ID. Defaults to TEST_CLIENT_ID or "
            f"ENTRA_APP_CLIENT_ID env vars, then falls back to VS Code's "
            f"client ID ({VSCODE_CLIENT_ID})."
        ),
    ),
    click.option(
        "--server-client-id",
        help="Fallback resource app registration client ID used only if PRM discovery does not publish scopes_supported.",
    ),
    click.option(
        "--scope",
        help="Scope to request. Defaults to the first PRM scopes_supported entry, then api://{server-client-id}/mcp.access.",
    ),
    click.option(
        "--open-browser/--no-open-browser",
        default=True,
        show_default=True,
        help="Open the authorization URL in a browser automatically.",
    ),
]


def apply_common_options(func):
    for option in reversed(COMMON_OPTIONS):
        func = option(func)
    return func


@click.group()
def cli() -> None:
    """Local MCP test client — PKCE auth code flow, no DCR."""


@cli.command()
@apply_common_options
def login(
    server_url: str | None,
    client_id: str | None,
    server_client_id: str | None,
    scope: str | None,
    open_browser: bool,
) -> None:
    """Discover PRM, get a token from Entra, then call MCP with Bearer auth."""
    run_flow(server_url, client_id, server_client_id, scope, open_browser)


@cli.command("fetch-token")
@apply_common_options
def fetch_token(
    server_url: str | None,
    client_id: str | None,
    server_client_id: str | None,
    scope: str | None,
    open_browser: bool,
) -> None:
    """Alias for login; retained for QA scripts and manual verification."""
    run_flow(server_url, client_id, server_client_id, scope, open_browser)


if __name__ == "__main__":
    cli()
