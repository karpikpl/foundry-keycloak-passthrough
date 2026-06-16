# agent_v4 — function-tool bridge to MCP (no token leaves the client)

> **Status: design only — no code yet.** This README captures the plan for a
> fourth agent variant. agent_v2 (OAuth Identity Passthrough via a Foundry
> RemoteTool connection) and agent_v3 (per-user PKCE, but an agent-per-user
> footprint) remain as-is.

## Goal

One shared Foundry agent definition that can be used by many users, with
**per-user authorization** to the downstream MCP server, and **no user token
ever stored in Foundry**.

agent_v2 satisfies "one agent for many users" but stores the user's refresh
token in the apihub connector. agent_v3 keeps tokens local but does not
reuse a single agent across users via `agent_reference`. agent_v4 aims to
combine both wins.

## Approach: the agent calls a *function tool*, not an MCP tool

Foundry's MCP tool requires `authorization` (or a Foundry connection) to be
supplied either on the agent definition or on the request. Per-request
overrides are not allowed when `agent_reference` is set
(`Not allowed when agent is specified` from the Responses API). So instead
of registering an MCP tool, we register a **function tool** that has no
auth concept at all. The user's local code becomes the bridge to MCP.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Foundry agent definition (one, shared by all users):               │
│    instructions: "...you can call call_mcp_tool(name, arguments)..."│
│    tools: [ function: call_mcp_tool ]      ← no auth, no MCP URL    │
└─────────────────────────────────────────────────────────────────────┘

For each user run, locally:
  1. PKCE login against Keycloak → user-scoped access token
     (stays on the user's process; never sent to Foundry).
  2. responses.create(agent_reference=..., input=prompt)
  3. Response output may include a function_call:
        { name: "call_mcp_tool", arguments: { name: "whoami", arguments: {} } }
  4. Local bridge: open an MCP client to MCP_SERVER_URL with
     Authorization: Bearer <user_token>, invoke the real tool, capture result.
  5. responses.create(
         previous_response_id=...,
         input=[{ type:"function_call_output", call_id:..., output:<result> }]
     )
  6. Loop until the model returns a normal message (or another tool call).
```

## Why this satisfies the security goals

- **Token isolation is enforced by process boundaries.** Each user runs their
  own python process with their own Keycloak token. Foundry never sees that
  token. Two users running side-by-side cannot reach each other's data.
- **Single shared agent definition.** All users target the same
  `agent_reference`; no per-user agent versions. The definition contains no
  secrets and no MCP URL — only a function-tool schema and instructions.
- **MCP server still does real OAuth.** The MCP server keeps validating the
  Keycloak access token exactly as it does today. Nothing changes server-side.
- **No Foundry connection required.** No apihub connector, no consent
  redirect, no shared refresh token. The MCP server can be marked as
  unauthenticated *from Foundry's point of view* because Foundry never calls
  it directly.

## Trade-offs vs. agent_v2

| Concern                        | agent_v2 (OIP via connection) | agent_v4 (function-tool bridge) |
| ------------------------------ | ----------------------------- | ------------------------------- |
| Token stored in Foundry?       | Yes (apihub)                  | No                              |
| One agent for all users?       | Yes                           | Yes                             |
| Tool call latency              | One hop (Foundry → apihub → MCP) | Two hops (model → user code → MCP) plus an extra Responses round-trip |
| Works in fully serverless agents (Foundry-only callers, e.g. agent_reference invoked from another agent) | Yes | **No — requires a local process to bridge tool calls** |
| Tool catalog discovery         | Foundry enumerates MCP tools automatically | We must either (a) describe `call_mcp_tool(name, arguments)` generically and let the model name the tool, or (b) enumerate MCP tools at startup and register one function tool per MCP tool |
| Approval UI (`require_approval`) | Built in                      | We implement (or skip)          |

## Two flavors of the function-tool surface

### Flavor A — single generic dispatcher (simplest)

One function tool on the agent:

```jsonc
{
  "type": "function",
  "name": "call_mcp_tool",
  "description": "Invoke a tool on the MCP server. The catalog of tool names and their argument schemas is provided in the system instructions.",
  "parameters": {
    "type": "object",
    "properties": {
      "name":      { "type": "string" },
      "arguments": { "type": "object" }
    },
    "required": ["name", "arguments"]
  }
}
```

Pros: one definition, never needs to change.
Cons: the model has to be told the tool catalog in the instructions; harder
to constrain arguments per tool.

### Flavor B — mirrored function tools

At agent-definition time, fetch `tools/list` from the MCP server (using a
service-account token, or anonymously if the server allows the discovery
endpoint) and generate one Foundry function tool per MCP tool, copying
their input schemas.

Pros: best UX for the model; per-tool argument validation.
Cons: agent definition must be regenerated when the MCP catalog changes.
Still one definition shared by all users at any given moment.

We'll start with **Flavor A** to keep the moving parts minimal.

## Components to build

1. **`agent.py`**
   - Loads `.env` (same vars as agent_v3 plus `AGENT_NAME`).
   - PKCE login to Keycloak (reuse code from `client/test_client.py` /
     `agent_v3/agent.py`).
   - Ensures the shared Foundry agent exists with the `call_mcp_tool` function
     tool. Idempotent: same agent name across users.
   - Drives the responses-loop:
     - `responses.create(agent_reference=..., input=prompt)`
     - For each `function_call` in `response.output` whose `name ==
       "call_mcp_tool"`:
         - Open `fastmcp.Client(server_url, auth=BearerAuth(user_token))`.
         - Call the requested MCP tool with the supplied arguments.
         - Submit `function_call_output` back via
           `responses.create(previous_response_id=..., input=[…])`.
     - Stop when the response contains only a `message`.

2. **`pyproject.toml`** — same deps as agent_v3 plus `fastmcp` (already in
   `client/`).

3. **`.env.example` / `.env`** — same shape as agent_v3, no
   `MCP_CONNECTION_NAME`, no Foundry connection involved.

4. **README.md** (this file) — kept up to date once we implement.

## Open questions / risks

- **Streaming of MCP tool output**: the function tool returns one synchronous
  string. If MCP tools stream large output we'll need to compress / chunk.
  Out of scope for first cut.

- **Token expiry mid-conversation**: Keycloak access tokens are short
  (5 min). The local bridge should refresh against `refresh_token` before
  each MCP call, or re-prompt the user. agent_v3 already hits this; reuse
  whatever pattern we settle on there.

- **Telling the model what tools are available**: in Flavor A, instructions
  must include the live MCP catalog. We can fetch it once at startup (as the
  current user) and inject it into the request via `instructions` override
  on `responses.create`.

- **Cross-process invocation**: this design assumes a human-driven CLI where
  a local process is always available to bridge tool calls. If we ever need
  Foundry to invoke this agent on its own (e.g. as a sub-agent in another
  agent's tool list), the bridge has to live somewhere else — probably the
  MCP server itself, in which case we're back to needing an authenticated
  channel from Foundry to that server, and agent_v2 becomes the right answer
  again.

## When to choose which variant

| Scenario                                                      | Use         |
| ------------------------------------------------------------- | ----------- |
| Production-ish, Foundry-mediated SSO, OK with apihub holding refresh token | agent_v2 |
| Per-user CLI / desktop, want zero shared state, one-off agent  | agent_v3 |
| Per-user CLI / desktop, want **one shared agent** definition, zero token storage in Foundry | **agent_v4** (this README) |
