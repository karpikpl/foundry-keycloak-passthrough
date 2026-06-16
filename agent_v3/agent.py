"""
Azure AI Foundry agent — single shared agent definition, **per-user token
injected at runtime** via structured inputs.

How this differs from agent_v2 (OAuth Identity Passthrough)
-----------------------------------------------------------
agent_v2 lets Foundry's apihub mint and store a refresh token per user.
This variant performs the OAuth flow locally (PKCE against Keycloak) so
no user credential is ever stored by Foundry.

How this differs from agent_v4 (function-tool bridge)
-----------------------------------------------------
agent_v4 avoids the Foundry MCP tool entirely and bridges every tool call
through the local process. This variant keeps using Foundry's native MCP
tool — tool discovery, approval UI, and a single round-trip — but uses
**Foundry structured inputs** (handlebar templates in the MCP tool's
`headers` field) to inject the bearer token only for the lifetime of one
HTTP request.

Doc: https://learn.microsoft.com/azure/foundry/agents/how-to/structured-inputs

Key isolation guarantees
------------------------
* One shared agent definition is created (or reused). It contains
  `headers={"Authorization": "Bearer {{userToken}}"}` — a placeholder, not a
  real token.
* On every request the caller supplies their own `userToken` via
  `structured_inputs`. Foundry replaces the placeholder before invoking
  MCP and discards the substituted value when the request ends.
* Two users cannot collide: each `responses.create()` call is independent
  and carries only its own caller's token in flight.

Flow per run
------------
  1. Local PKCE login against Keycloak → access token.
     `--idp-hint entra` skips the Keycloak login screen and federates to Entra.
  2. Ensure the shared agent definition exists (idempotent).
  3. responses.create(
         agent_reference=...,
         structured_inputs={"userToken": access_token},
         input=prompt,
     )
  4. Handle approval loop if `require_approval="always"`.

Run:
    uv run agent.py [--prompt "..."] [--idp-hint entra]

Environment (loaded from .env or AZD env automatically):
    FOUNDRY_ENDPOINT   - https://<account>.cognitiveservices.azure.com/api/projects/<project>
    MCP_SERVER_URL     - https://<webapp>.azurewebsites.net/mcp
    KEYCLOAK_BASE_URL  - https://<keycloak>.azurecontainerapps.io
    KEYCLOAK_REALM     - mcp-demo
    CLIENT_ID          - mcp-server
    CLIENT_SECRET      - confidential client secret for mcp-server
    AGENT_MODEL        - deployment name (default: gpt-4o)
    AGENT_NAME         - shared agent name (default: cloud-helper-agent-v3)
    CALLBACK_PORT      - loopback port (default: 55899)
"""
from __future__ import annotations

import argparse
import asyncio
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

import httpx
from azure.ai.projects.aio import AIProjectClient
from azure.ai.projects.models import (
    MCPTool,
    PromptAgentDefinition,
    StructuredInputDefinition,
)
from azure.identity.aio import DefaultAzureCredential
from dotenv import load_dotenv
from openai import NOT_GIVEN
from openai.types.responses.response_input_param import McpApprovalResponse

load_dotenv(Path(__file__).with_name(".env"))


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        print(f"❌  Missing required env var: {name}", file=sys.stderr)
        sys.exit(1)
    return value


# ── PKCE helpers (mirror client/test_client.py) ───────────────────────────────

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
        params = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
        type(self).received = params
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(
            b"<html><body><h2>Authorization received.</h2>"
            b"<p>You may close this tab.</p></body></html>"
        )

    def log_message(self, *_a, **_k):
        return


def _wait_for_callback(port: int) -> dict[str, str]:
    server = http.server.HTTPServer(("127.0.0.1", port), _CallbackHandler)
    try:
        while not _CallbackHandler.received:
            server.handle_request()
    finally:
        server.server_close()
    return _CallbackHandler.received


def _login_keycloak(
    kc_base: str,
    realm: str,
    client_id: str,
    client_secret: str | None,
    scope: str,
    idp_hint: str | None,
    callback_port: int,
    open_browser: bool,
) -> str:
    """Run a local PKCE flow against Keycloak; return an access token."""
    discovery_url = f"{kc_base.rstrip('/')}/realms/{realm}/.well-known/openid-configuration"
    discovery = httpx.get(discovery_url, timeout=15.0).raise_for_status().json()

    redirect_uri = f"http://127.0.0.1:{callback_port}/callback"
    verifier, challenge = _pkce_pair()
    state = secrets.token_urlsafe(16)
    auth_params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": scope,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    if idp_hint:
        auth_params["kc_idp_hint"] = idp_hint
    auth_url = discovery["authorization_endpoint"] + "?" + urllib.parse.urlencode(auth_params)

    print("\n────────────────────────────────────────────────────────────")
    print("🔑  Open this URL to sign in:")
    print(f"   {auth_url}")
    print("────────────────────────────────────────────────────────────\n")
    if open_browser:
        webbrowser.open(auth_url)

    received = _wait_for_callback(callback_port)
    if received.get("state") != state:
        sys.exit(f"❌ State mismatch: expected {state!r}, got {received.get('state')!r}")
    if "code" not in received:
        sys.exit(f"❌ Authorization error: {received}")

    token_data = {
        "grant_type": "authorization_code",
        "code": received["code"],
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "code_verifier": verifier,
    }
    if client_secret:
        token_data["client_secret"] = client_secret

    resp = httpx.post(discovery["token_endpoint"], data=token_data, timeout=30.0)
    if resp.status_code != 200:
        sys.exit(f"❌ Token exchange failed ({resp.status_code}): {resp.text}")
    tokens = resp.json()
    access_token = tokens["access_token"]

    claims = _decode_jwt(access_token)
    print("--- access_token claims ---")
    for k in ("iss", "aud", "azp", "scope", "preferred_username", "email", "sub"):
        if k in claims:
            print(f"  {k:22} {claims[k]}")
    print("---------------------------\n")
    return access_token


# ── Foundry agent run ─────────────────────────────────────────────────────────

async def run_agent(prompt: str, idp_hint: str | None, open_browser: bool) -> None:
    endpoint     = _require("FOUNDRY_ENDPOINT").rstrip("/")
    mcp_url      = _require("MCP_SERVER_URL")
    kc_base      = _require("KEYCLOAK_BASE_URL")
    realm        = os.environ.get("KEYCLOAK_REALM", "mcp-demo")
    client_id    = os.environ.get("CLIENT_ID", "mcp-server")
    client_secret = os.environ.get("CLIENT_SECRET") or None
    scope        = os.environ.get("OAUTH_SCOPE", "openid profile email mcp.access")
    callback_port = int(os.environ.get("CALLBACK_PORT", "55899"))
    model        = os.environ.get("AGENT_MODEL", "gpt-4o")
    agent_name   = os.environ.get("AGENT_NAME", "cloud-helper-agent-v3")

    # 1) Local PKCE login → user-specific Keycloak access token.
    access_token = _login_keycloak(
        kc_base, realm, client_id, client_secret, scope,
        idp_hint, callback_port, open_browser,
    )

    # 2) MCP tool with a templated bearer header. The header VALUE must be
    # *only* the placeholder — Foundry rejects sensitive headers that mix
    # literal text with templates (e.g. "Bearer {{userToken}}"). So we stash
    # the full "Bearer <token>" string in the structured input itself.
    mcp_tool = MCPTool(
        server_label="cloud_helper_mcp",
        server_url=mcp_url,
        headers={"Authorization": "{{userToken}}"},
        require_approval="always",
    )

    async with DefaultAzureCredential() as cred:
        async with AIProjectClient(endpoint=endpoint, credential=cred) as client:
            print(f"🤖  Ensuring shared agent '{agent_name}' (model={model}) ...")
            agent = await client.agents.create_version(
                agent_name=agent_name,
                definition=PromptAgentDefinition(
                    model=model,
                    instructions=(
                        "You're a Bro agent, who talks like a bro and acts like a bro. "
                        "You're bro-code tells you to be chill, brutaly honest and helpful, "
                        "but you also have to follow the rules of the MCP tool. "
                        "When asked about the current user, call the whoami tool. "
                    ),
                    tools=[mcp_tool],
                    structured_inputs={
                        "userToken": StructuredInputDefinition(
                            description="Per-user Keycloak access token forwarded to the MCP server.",
                            required=True,
                            schema={"type": "string"},
                        ),
                    },
                ),
            )
            print(f"    agent version={agent.version}")

            openai = client.get_openai_client()

            conversation = await openai.conversations.create(
                items=[{"type": "message", "role": "user", "content": prompt}]
            )
            print(f"    conversation_id={conversation.id}")
            print(f"\n💬  User: {prompt}\n")

            # 3) Per-request structured_inputs carries the user's token.
            response_id = None
            pending_approvals: list = []

            while True:
                response = await openai.responses.create(
                    conversation=conversation.id if response_id is None else NOT_GIVEN,
                    previous_response_id=response_id if response_id else NOT_GIVEN,
                    extra_body={
                        "agent_reference": {"name": agent_name, "type": "agent_reference"},
                        "structured_inputs": {"userToken": f"Bearer {access_token}"},
                    },
                    input=pending_approvals or "",
                )
                response_id = response.id
                pending_approvals = []

                for item in response.output:
                    if getattr(item, "type", None) == "mcp_approval_request":
                        tool_name = getattr(item, "name", "tool")
                        print(f"    🔐  Auto-approving MCP call: {tool_name}")
                        pending_approvals.append(
                            McpApprovalResponse(
                                type="mcp_approval_response",
                                approve=True,
                                approval_request_id=item.id,
                            )
                        )

                if not pending_approvals:
                    break

            output_text = getattr(response, "output_text", None)
            if output_text:
                print(f"\n🤖  Assistant: {output_text}")
            else:
                for item in response.output:
                    if getattr(item, "type", None) == "message":
                        for block in getattr(item, "content", []):
                            if getattr(block, "type", None) == "output_text":
                                print(f"\n🤖  Assistant: {block.text}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Foundry agent — shared agent, per-user Keycloak token via structured_inputs"
    )
    parser.add_argument("--prompt", default="Call the whoami tool and tell me who I am.")
    parser.add_argument("--idp-hint", default=os.environ.get("IDP_HINT") or None,
                        help="Keycloak kc_idp_hint (e.g. 'entra' to skip the Keycloak login UI).")
    parser.add_argument("--no-open-browser", dest="open_browser",
                        action="store_false", default=True)
    args = parser.parse_args()
    asyncio.run(run_agent(args.prompt, args.idp_hint, args.open_browser))


if __name__ == "__main__":
    main()
