"""Local MCP test client for the Keycloak-passthrough demo.

The Keycloak realm hosts a confidential client (`mcp-server`) that this test
client also uses: a desktop PKCE flow with the client_secret sent on the
token exchange. The flow:

  1. GET the realm's OIDC discovery doc.
  2. Pop a browser → realm authorization endpoint with PKCE + a loopback
     redirect to http://127.0.0.1:<port>/callback.
  3. Receive the auth code on the loopback HTTP server, swap it for an
     access_token at the realm token endpoint (PKCE verifier + client secret).
  4. List tools and call `hello` on the MCP server using the bearer token.

If the realm's identity provider broker is configured (Entra federated as
`entra`), Keycloak's login page shows a "Microsoft Entra ID" button. Use
`--idp-hint entra` to skip the local-login screen and go straight to Entra.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import urllib.parse
import webbrowser
from pathlib import Path
from typing import Any

import anyio
import httpx
from dotenv import load_dotenv
from fastmcp import Client
from fastmcp.client.auth import BearerAuth

ENV_FILE = Path(__file__).with_name(".env")
load_dotenv(ENV_FILE)


def _require(name: str, fallback: str | None = None) -> str:
    val = os.environ.get(name) or fallback
    if not val:
        sys.exit(f"❌ Missing required env var: {name}")
    return val


def _pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)[:128]
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()
    return verifier, challenge


def _decode_jwt(token: str) -> dict[str, Any]:
    try:
        body = token.split(".")[1]
        body += "=" * (-len(body) % 4)
        return json.loads(base64.urlsafe_b64decode(body))
    except Exception:
        return {}


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    received: dict[str, str] = {}

    def do_GET(self):  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        params = dict(urllib.parse.parse_qsl(parsed.query))
        type(self).received = params
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        body = "<html><body><h2>Authorization received.</h2>"
        body += "<p>You may close this tab.</p></body></html>"
        self.wfile.write(body.encode())

    def log_message(self, *_args, **_kwargs):  # silence default logging
        return


def _wait_for_callback(port: int) -> dict[str, str]:
    server = http.server.HTTPServer(("127.0.0.1", port), _CallbackHandler)
    try:
        # Block until exactly one request hits /callback. This is enough for
        # the OAuth redirect; subsequent favicon hits are not awaited.
        while not _CallbackHandler.received:
            server.handle_request()
    finally:
        server.server_close()
    return _CallbackHandler.received


def _authorize(
    discovery: dict[str, Any],
    client_id: str,
    redirect_uri: str,
    scope: str,
    idp_hint: str | None,
    open_browser: bool,
) -> tuple[str, str]:
    verifier, challenge = _pkce_pair()
    state = secrets.token_urlsafe(16)
    params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": scope,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    if idp_hint:
        params["kc_idp_hint"] = idp_hint
    url = discovery["authorization_endpoint"] + "?" + urllib.parse.urlencode(params)

    print("\n────────────────────────────────────────────────────────────")
    print("Open this URL to authenticate:")
    print(url)
    print("────────────────────────────────────────────────────────────\n")
    if open_browser:
        webbrowser.open(url)

    received = _wait_for_callback(int(redirect_uri.rsplit(":", 1)[1].split("/")[0]))
    if received.get("state") != state:
        sys.exit(f"❌ State mismatch: expected {state!r}, got {received.get('state')!r}")
    if "code" not in received:
        sys.exit(f"❌ Authorization error: {received}")
    return received["code"], verifier


def _exchange(
    discovery: dict[str, Any],
    client_id: str,
    client_secret: str | None,
    redirect_uri: str,
    code: str,
    verifier: str,
) -> dict[str, Any]:
    data = {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "code_verifier": verifier,
    }
    if client_secret:
        data["client_secret"] = client_secret
    resp = httpx.post(
        discovery["token_endpoint"], data=data, timeout=30.0
    )
    if resp.status_code != 200:
        sys.exit(f"❌ Token exchange failed ({resp.status_code}): {resp.text}")
    return resp.json()


async def _call_tools(server_url: str, access_token: str) -> None:
    async with Client(server_url, auth=BearerAuth(access_token)) as client:
        tools = await client.list_tools()
        names = [t.name for t in tools]
        print(f"\n✅ tools/list returned {len(names)} tool(s): {names}")
        if "hello" in names:
            result = await client.call_tool("hello", {"name": "World"})
            text = result.content[0].text if result.content else ""
            print("\n--- hello tool output ---")
            print(text)
            print("-------------------------")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="MCP test client — PKCE against Keycloak realm"
    )
    parser.add_argument("--server-url", default=os.environ.get("SERVER_URL"))
    parser.add_argument("--keycloak-base-url", default=os.environ.get("KEYCLOAK_BASE_URL"))
    parser.add_argument("--realm", default=os.environ.get("KEYCLOAK_REALM", "mcp-demo"))
    parser.add_argument("--client-id", default=os.environ.get("CLIENT_ID", "mcp-server"))
    parser.add_argument("--client-secret", default=os.environ.get("CLIENT_SECRET", ""))
    parser.add_argument("--scope", default="openid profile email mcp.access")
    parser.add_argument(
        "--idp-hint",
        default=None,
        help="Keycloak kc_idp_hint to skip the local login screen (e.g. 'entra').",
    )
    parser.add_argument("--no-open-browser", dest="open_browser",
                        action="store_false", default=True)
    parser.add_argument("--callback-port", type=int, default=int(os.environ.get("CALLBACK_PORT", "55899")),
                        help="Loopback port for the OAuth redirect. Must match the port registered "
                             "on the Keycloak client redirect URIs.")
    args = parser.parse_args()

    server_url = _require("SERVER_URL", args.server_url)
    kc_base = _require("KEYCLOAK_BASE_URL", args.keycloak_base_url).rstrip("/")
    realm = args.realm
    client_id = args.client_id
    client_secret = args.client_secret or None  # public client if empty

    discovery_url = f"{kc_base}/realms/{realm}/.well-known/openid-configuration"
    print(f"Discovery: {discovery_url}")
    discovery = httpx.get(discovery_url, timeout=15.0).raise_for_status().json()
    print(f"Authorization server: {discovery['issuer']}")

    port = args.callback_port
    redirect_uri = f"http://127.0.0.1:{port}/callback"
    print(f"Redirect URI:        {redirect_uri}")
    print(f"Client ID:           {client_id}")
    print(f"Scope:               {args.scope}")
    if args.idp_hint:
        print(f"kc_idp_hint:         {args.idp_hint}")
    if not client_secret:
        print("Client secret:       <none — relying on PKCE only>")

    code, verifier = _authorize(
        discovery, client_id, redirect_uri, args.scope, args.idp_hint, args.open_browser,
    )
    tokens = _exchange(discovery, client_id, client_secret, redirect_uri, code, verifier)

    access_token = tokens["access_token"]
    claims = _decode_jwt(access_token)
    print("\n--- access_token claims ---")
    for k in ("iss", "aud", "azp", "scope", "preferred_username", "email", "name", "sub"):
        if k in claims:
            print(f"  {k:22} {claims[k]}")
    print("---------------------------")

    anyio.run(_call_tools, server_url, access_token)


if __name__ == "__main__":
    main()
