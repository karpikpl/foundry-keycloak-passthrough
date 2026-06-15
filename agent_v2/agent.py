"""
Azure AI Foundry agent with MCP tool + OAuth Identity Passthrough.

Uses the azure-ai-projects v2.1.0 pattern:
  - AIProjectClient.agents.create_version() + PromptAgentDefinition
  - openai_client.conversations.create() + responses.create() with agent_reference
  - McpApprovalResponse loop for require_approval="always"

MCPTool.project_connection_id tells Foundry to use the named connection for
OAuth Identity Passthrough — Foundry fetches and forwards the token on behalf
of the signed-in user. No manual token acquisition needed.

On first run the connection may require OAuth consent — the agent prints the
consent URL and opens it in the browser automatically.  Complete the consent
flow in the browser, then re-run the agent.

Pre-requisites:
  - `az login` with an account that has access to the Foundry project.
  - The Foundry connection (MCP_CONNECTION_NAME) must exist with the correct
    OAuth scope. Run `azd provision` to create/recreate it.

Run:
    uv run agent.py [--prompt "your prompt"] [--no-cleanup]

Environment (loaded from .env or AZD env automatically):
    FOUNDRY_ENDPOINT      - full project URL:
                            https://aif-xxx.cognitiveservices.azure.com/api/projects/proj-xxx
    MCP_SERVER_URL        - e.g. https://cloud-helper-mcp-xxx.azurewebsites.net/mcp
    MCP_CONNECTION_NAME   - Foundry connection name (e.g. cloud-helper-mcp-xxx)
    AGENT_MODEL           - deployment name (default: gpt-4o)
    AGENT_NAME            - agent name in Foundry (default: mcp-agent)
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
import webbrowser
from pathlib import Path

from azure.ai.projects.aio import AIProjectClient
from azure.ai.projects.models import MCPTool, PromptAgentDefinition
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


# ── agent ──────────────────────────────────────────────────────────────────────

async def run_agent(prompt: str, cleanup: bool) -> None:
    endpoint        = _require("FOUNDRY_ENDPOINT").rstrip("/")
    mcp_url         = _require("MCP_SERVER_URL")
    connection_name = _require("MCP_CONNECTION_NAME")
    model           = os.environ.get("AGENT_MODEL", "gpt-4o")
    agent_name      = os.environ.get("AGENT_NAME", "mcp-bro-agent")

    # project_connection_id enables OAuth Identity Passthrough:
    # Foundry fetches a delegated token for the signed-in user via the named
    # connection and forwards it to the MCP server automatically.
    mcp_tool = MCPTool(
        server_label="cloud_helper_mcp",
        server_url=mcp_url,
        project_connection_id=connection_name,
        require_approval="always",
    )

    async with DefaultAzureCredential() as cred:
        async with AIProjectClient(endpoint=endpoint, credential=cred) as client:
            print(f"\n🤖  Creating agent '{agent_name}' (model={model}, connection={connection_name}) ...")
            agent = await client.agents.create_version(
                agent_name=agent_name,
                definition=PromptAgentDefinition(
                    model=model,
                    instructions=(
                        "You're a Bro agent, who talks like a bro and acts like a bro. "
                        "You're bro-code tells you to be chill, brutaly honest and helpful, but you also have to follow the rules of the MCP tool. "
                        "When asked about the current user, call the whoami tool. "
                    ),
                    tools=[mcp_tool],
                ),
            )
            print(f"    agent version={agent.version}")

            openai = client.get_openai_client()

            conversation = await openai.conversations.create(
                items=[{"type": "message", "role": "user", "content": prompt}]
            )
            print(f"    conversation_id={conversation.id}")
            print(f"\n💬  User: {prompt}\n")

            # Run + handle approval loop and OAuth consent requests
            response_id = None
            pending_approvals: list = []
            retry = False

            while True:
                response = await openai.responses.create(
                    conversation=conversation.id if response_id is None else NOT_GIVEN,
                    previous_response_id=response_id if response_id else NOT_GIVEN,
                    extra_body={"agent_reference": {"name": agent_name, "type": "agent_reference"}},
                    input=pending_approvals or "",
                )
                response_id = response.id
                pending_approvals = []
                retry = False

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

                    elif item_type == "oauth_consent_request":
                        # consent_link is not yet in the pydantic model — read from raw dict
                        raw = item.__dict__ if hasattr(item, "__dict__") else {}
                        consent_link = raw.get("consent_link") or getattr(item, "consent_link", None)
                        if consent_link:
                            print(f"\n🔑  OAuth consent required for connection '{connection_name}'.")
                            print(f"    Opening browser: {consent_link}\n")
                            webbrowser.open(consent_link)
                        else:
                            print(f"\n⚠️  OAuth consent required but no consent_link found.")
                        input("    Complete consent in the browser, then press Enter to continue...")
                        response_id = None
                        retry = True
                        break

                if not pending_approvals and not retry:
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

            if cleanup:
                try:
                    await client.agents.delete(agent_name=agent_name)
                    print(f"\n🗑️  Deleted agent '{agent_name}'.")
                except Exception:
                    pass


def main() -> None:
    parser = argparse.ArgumentParser(description="Run a Foundry v2 agent with MCP OAuth Identity Passthrough")
    parser.add_argument("--prompt", default="Call the whoami tool and tell me who I am.", help="Prompt to send")
    parser.add_argument("--cleanup", action="store_true", default=True)
    parser.add_argument("--no-cleanup", dest="cleanup", action="store_false")
    args = parser.parse_args()
    asyncio.run(run_agent(args.prompt, args.cleanup))


if __name__ == "__main__":
    main()

