from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration for the FastMCP protected resource.

    This server validates JWTs issued by a Keycloak realm. Entra ID is
    federated *into* Keycloak via an OIDC identity provider broker, so the
    MCP server never talks to Entra directly — it only trusts Keycloak.
    """

    keycloak_base_url: str = Field(alias="KEYCLOAK_BASE_URL")
    keycloak_realm: str = Field(default="mcp-demo", alias="KEYCLOAK_REALM")
    client_id: str = Field(alias="CLIENT_ID")
    audience: str | None = Field(default=None, alias="AUDIENCE")
    resource_host: str = Field(alias="RESOURCE_HOST")
    port: int = Field(default=8000, alias="PORT")

    model_config = SettingsConfigDict(
        env_file=Path(__file__).with_name(".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    @property
    def resolved_audience(self) -> str:
        return self.audience or self.client_id

    @property
    def jwt_audience(self) -> str | list[str]:
        """Audience values accepted when validating Keycloak access tokens.

        The Keycloak client adds an audience mapper so its own client_id is
        included in the `aud` claim; we also accept the resource URL form
        if a caller used RFC 8707 resource indicators.
        """
        audiences: list[str] = [self.resolved_audience]
        rfc8707 = f"{self.resource_url}/mcp"
        if rfc8707 not in audiences:
            audiences.append(rfc8707)
        return audiences if len(audiences) > 1 else audiences[0]

    @property
    def scope_resource(self) -> str:
        return f"{self.resource_url}/mcp"

    @property
    def issuer(self) -> str:
        return f"{self.keycloak_base_url.rstrip('/')}/realms/{self.keycloak_realm}"

    @property
    def jwks_url(self) -> str:
        return f"{self.issuer}/protocol/openid-connect/certs"

    @property
    def authorization_url(self) -> str:
        return f"{self.issuer}/protocol/openid-connect/auth"

    @property
    def token_url(self) -> str:
        return f"{self.issuer}/protocol/openid-connect/token"

    @property
    def resource_url(self) -> str:
        return f"https://{self.resource_host}"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
