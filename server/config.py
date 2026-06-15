from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration for the FastMCP protected resource."""

    tenant_id: str = Field(
        validation_alias=AliasChoices("TENANT_ID", "AZURE_TENANT_ID")
    )
    client_id: str = Field(alias="CLIENT_ID")
    audience: str | None = Field(default=None, alias="AUDIENCE")
    resource_app_id: str | None = Field(default=None, alias="RESOURCE_APP_ID")
    resource_host: str = Field(alias="RESOURCE_HOST")
    port: int = Field(default=8000, alias="PORT")

    model_config = SettingsConfigDict(
        env_file=Path(__file__).with_name(".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    @property
    def resolved_audience(self) -> str:
        """Primary audience value configured for this resource server."""
        return self.audience or self.client_id

    @property
    def jwt_audience(self) -> str | list[str]:
        """Audience value(s) accepted when validating Entra access tokens.

        Tokens may be issued for either the https Application ID URI (when the
        client uses the RFC 8707 resource indicator) or the api:// URI (when
        Foundry or other callers request the scope directly without a resource
        parameter).  Accept both so neither path breaks.
        """
        audiences: list[str] = [f"{self.resource_url}/mcp"]
        if self.audience:
            audiences.append(self.audience)
        if self.resource_app_id:
            audiences.append(self.resource_app_id)
        return audiences if len(audiences) > 1 else audiences[0]

    @property
    def scope_resource(self) -> str:
        """Resource prefix used to advertise the mcp.access scope.

        Must match the https Application ID URI registered in Entra so that
        FastMCP's RFC 8707 resource indicator and the scope prefix agree,
        avoiding AADSTS9010010.
        """
        return f"{self.resource_url}/mcp"

    @property
    def issuer(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/v2.0"

    @property
    def jwks_url(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/discovery/v2.0/keys"

    @property
    def resource_url(self) -> str:
        return f"https://{self.resource_host}"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
