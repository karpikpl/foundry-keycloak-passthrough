"""
Azure AI Foundry agent — single shared agent definition, **per-user token
injected at runtime** via structured inputs.

This variant points at the **Leena.ai** sandbox MCP server and uses
Leena's hosted OAuth 2.0 authorization-code flow as the identity
provider (no Keycloak, no Entra in the loop). It is otherwise identical
to ``agent_v3``:

* One shared Foundry agent definition with ``headers={"Authorization":
  "{{userToken}}"}`` (pure-placeholder, since Foundry refuses sensitive
  headers that mix literal text with templates).
* Per-request, the caller does a local OAuth login against Leena and
  passes ``"Bearer <access_token>"`` via ``structured_inputs.userToken``.
* No user credential is ever persisted by Foundry.

Endpoints (overridable via env):
    Authorize: https://sandbox-chat.leena.ai/api/oauth/authorize
    Token:     https://sandbox-chat.leena.ai/api/oauth/token
    MCP:       https://sandbox-aic.leena.ai/mcp/

Run:
    uv run agent.py [--prompt "..."]

Environment (loaded from .env automatically):
    FOUNDRY_ENDPOINT     - https://<account>.cognitiveservices.azure.com/api/projects/<project>
    MCP_SERVER_URL       - default https://sandbox-aic.leena.ai/mcp/
    LEENA_AUTHORIZE_URL  - default https://sandbox-chat.leena.ai/api/oauth/authorize
    LEENA_TOKEN_URL      - default https://sandbox-chat.leena.ai/api/oauth/token
    CLIENT_ID            - Leena OAuth client ID
    CLIENT_SECRET        - Leena OAuth client secret
    OAUTH_SCOPE          - optional, space-separated scopes
    CALLBACK_PORT        - loopback port (default 8765)
    CALLBACK_PATH        - loopback path (default /callback)
    AGENT_MODEL          - deployment name (default: gpt-4o)
    AGENT_NAME           - shared agent name (default: cloud-helper-agent-v5)
    USE_PKCE             - "true"/"false" (default true)
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


# ── PKCE helpers ──────────────────────────────────────────────────────────────

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


def _login_leena(
    authorize_url: str,
    token_url: str,
    client_id: str,
    client_secret: str | None,
    scope: str | None,
    callback_port: int,
    callback_path: str,
    use_pkce: bool,
    open_browser: bool,
) -> str:
    """Run a local OAuth authorization-code flow against Leena; return an access token."""
    redirect_uri = f"http://127.0.0.1:{callback_port}{callback_path}"
    state = secrets.token_urlsafe(16)
    auth_params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "state": state,
    }
    if scope:
        auth_params["scope"] = scope

    verifier: str | None = None
    if use_pkce:
        verifier, challenge = _pkce_pair()
        auth_params["code_challenge"] = challenge
        auth_params["code_challenge_method"] = "S256"

    auth_url = authorize_url + "?" + urllib.parse.urlencode(auth_params)

    print("\n────────────────────────────────────────────────────────────")
    print("🔑  Open this URL to sign in to Leena:")
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
        "redirectUri": redirect_uri,
        "clientId": client_id,
    }
    if verifier:
        token_data["code_verifier"] = verifier
    if client_secret:
        token_data["clientSecret"] = client_secret

    resp = httpx.post(token_url, json=token_data, timeout=30.0)
    if resp.status_code != 200:
        sys.exit(f"❌ Token exchange failed ({resp.status_code}): {resp.text}")
    tokens = resp.json()
    access_token = tokens.get("access_token")
    if not access_token:
        sys.exit(f"❌ Token response missing access_token: {tokens}")

    claims = _decode_jwt(access_token)
    if claims:
        print("--- access_token claims ---")
        for k in ("iss", "aud", "azp", "scope", "preferred_username", "email", "sub", "exp"):
            if k in claims:
                print(f"  {k:22} {claims[k]}")
        print("---------------------------\n")
    else:
        print("(opaque access token returned; skipping claim dump)\n")
    return access_token


# ── Foundry agent run ─────────────────────────────────────────────────────────

async def run_agent(prompt: str, open_browser: bool) -> None:
    endpoint     = _require("FOUNDRY_ENDPOINT").rstrip("/")
    mcp_url      = os.environ.get("MCP_SERVER_URL", "https://sandbox-aic.leena.ai/mcp/")
    authorize_url = os.environ.get("LEENA_AUTHORIZE_URL",
                                   "https://sandbox-chat.leena.ai/api/oauth/authorize")
    token_url    = os.environ.get("LEENA_TOKEN_URL",
                                  "https://sandbox-chat.leena.ai/api/oauth/token")
    client_id    = _require("CLIENT_ID")
    client_secret = os.environ.get("CLIENT_SECRET") or None
    scope        = os.environ.get("OAUTH_SCOPE") or None
    callback_port = int(os.environ.get("CALLBACK_PORT", "8765"))
    callback_path = os.environ.get("CALLBACK_PATH", "/callback")
    use_pkce     = os.environ.get("USE_PKCE", "true").lower() != "false"
    model        = os.environ.get("AGENT_MODEL", "gpt-4o")
    agent_name   = os.environ.get("AGENT_NAME", "cloud-helper-agent-v5")

    # 1) Local OAuth login → user-specific Leena access token.
    access_token = _login_leena(
        authorize_url, token_url, client_id, client_secret, scope,
        callback_port, callback_path, use_pkce, open_browser,
    )

    # 2) MCP tool with a templated bearer header. The header VALUE must be
    # *only* the placeholder — Foundry rejects sensitive headers that mix
    # literal text with templates (e.g. "Bearer {{userToken}}"). So we stash
    # the full "Bearer <token>" string in the structured input itself.
    mcp_tool = MCPTool(
        server_label="leena_mcp",
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
                        "You are a helpful assistant backed by the Leena.ai MCP "
                        "server. Use the available MCP tools to answer the user's "
                        "questions. When asked who the current user is, call the "
                        "appropriate identity tool."
                    ),
                    tools=[mcp_tool],
                    structured_inputs={
                        "userToken": StructuredInputDefinition(
                            description="Per-user Leena OAuth access token forwarded to the MCP server.",
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
                    item_type = getattr(item, "type", None)
                    if item_type == "mcp_approval_request":
                        tool_name = getattr(item, "name", "tool")
                        print(f"    🔐  Auto-approving MCP call: {tool_name}")
                        pending_approvals.append(
                            McpApprovalResponse(
                                type="mcp_approval_response",
                                approve=True,
                                approval_request_id=item.id,
                            )
                        )
                    elif item_type == "mcp_call":
                        tool_name = getattr(item, "name", "tool")
                        args = getattr(item, "arguments", None)
                        output = getattr(item, "output", None)
                        error = getattr(item, "error", None)
                        print(f"\n    🛠  MCP call: {tool_name}")
                        if args:
                            print(f"       args:   {args}")
                        if error:
                            print(f"       error:  {error}")
                        if output is not None:
                            preview = output if isinstance(output, str) else json.dumps(output, default=str)
                            if len(preview) > 2000:
                                preview = preview[:2000] + f"... [{len(preview)} chars total]"
                            print(f"       output: {preview}")
                    elif item_type == "mcp_list_tools":
                        tools = getattr(item, "tools", []) or []
                        names = [getattr(t, "name", "?") for t in tools]
                        print(f"    📜  MCP tools advertised: {names}")

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
        description="Foundry agent — shared agent, per-user Leena.ai token via structured_inputs"
    )
    parser.add_argument("--prompt", default="Who am I? Call the appropriate MCP tool to find out.")
    parser.add_argument("--no-open-browser", dest="open_browser",
                        action="store_false", default=True)
    args = parser.parse_args()
    asyncio.run(run_agent(args.prompt, args.open_browser))


if __name__ == "__main__":
    main()
