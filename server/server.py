from __future__ import annotations

import uvicorn
from fastmcp import Context, FastMCP
from fastmcp.server.auth import RemoteAuthProvider
from fastmcp.server.auth.providers.jwt import JWTVerifier
from mcp.server.auth.handlers.metadata import ProtectedResourceMetadataHandler
from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.auth.routes import cors_middleware
from mcp.shared.auth import ProtectedResourceMetadata
from starlette.responses import JSONResponse
from starlette.routing import Route

from config import get_settings


def _protected_resource_metadata() -> ProtectedResourceMetadata:
    settings = get_settings()
    return ProtectedResourceMetadata(
        resource=f"{settings.resource_url}/mcp",
        authorization_servers=[settings.issuer],
        scopes_supported=[f"{settings.scope_resource}/mcp.access"],
        resource_name="Cloud Helper MCP",
    )


def extract_token_info() -> dict[str, str]:
    access_token = get_access_token()
    claims = access_token.claims if access_token else {}
    return {
        "display_name": (
            claims.get("name")
            or claims.get("preferred_username")
            or claims.get("upn")
            or claims.get("email")
            or (access_token.client_id if access_token else "")
        ),
        "upn": (
            claims.get("preferred_username")
            or claims.get("upn")
            or claims.get("email")
            or ""
        ),
        "oid": claims.get("oid") or claims.get("sub") or "",
        "tid": claims.get("tid") or "",
    }


def _create_mcp() -> FastMCP:
    settings = get_settings()
    auth = RemoteAuthProvider(
        token_verifier=JWTVerifier(
            jwks_uri=settings.jwks_url,
            issuer=settings.issuer,
            audience=settings.jwt_audience,
            required_scopes=["mcp.access"],
        ),
        authorization_servers=[settings.issuer],
        base_url=settings.resource_url,
        scopes_supported=[f"{settings.scope_resource}/mcp.access"],
        resource_name="Cloud Helper MCP",
    )
    return FastMCP("Cloud Helper MCP", auth=auth)


mcp = _create_mcp()


@mcp.tool(description="Return all JWT claims for the authenticated caller.")
def whoami(ctx: Context) -> dict:
    access_token = get_access_token()
    claims = dict(access_token.claims) if access_token else {}
    ctx.info(f"whoami invoked (oid={claims.get('oid', '')})")
    return {
        "claims": claims,
        "scopes": list(access_token.scopes) if access_token else [],
        "client_id": access_token.client_id if access_token else None,
    }


@mcp.tool(description="Return a hello world message for authenticated callers.")
def hello(name: str, ctx: Context) -> str:
    access_token = get_access_token()
    token_info = extract_token_info()
    display_name = token_info.get("display_name") or (
        access_token.client_id if access_token else "unknown"
    )
    upn = token_info.get("upn", "")
    oid = token_info.get("oid", "")
    tid = token_info.get("tid", "")
    scopes = ", ".join(access_token.scopes) if access_token else ""

    ctx.info(f"hello invoked by {display_name} (oid={oid})")
    return (
        f"Hello, {name}! You are authenticated as:\n"
        f"  Name:    {display_name}\n"
        f"  UPN:     {upn}\n"
        f"  OID:     {oid}\n"
        f"  Tenant:  {tid}\n"
        f"  Scopes:  {scopes}"
    )


app = mcp.http_app(
    stateless_http=True,
    json_response=True,
)


async def healthcheck(_request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


# VS Code probes the root RFC 9728 endpoint before the path-scoped /mcp variant.
app.router.routes.insert(
    0,
    Route(
        "/.well-known/oauth-protected-resource",
        endpoint=cors_middleware(
            ProtectedResourceMetadataHandler(_protected_resource_metadata()).handle,
            ["GET", "OPTIONS"],
        ),
        methods=["GET", "OPTIONS"],
    ),
)
app.router.routes.insert(0, Route("/health", endpoint=healthcheck, methods=["GET"]))
app.router.routes.insert(0, Route("/", endpoint=healthcheck, methods=["GET"]))


def main() -> None:
    settings = get_settings()
    uvicorn.run(app, host="0.0.0.0", port=settings.port)


if __name__ == "__main__":
    main()
