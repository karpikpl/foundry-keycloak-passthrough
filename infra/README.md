# infra/README.md — AZD + Bicep Setup Guide
<!-- Created: 2026-05-09T04:22:42Z -->
<!-- Supersedes: scripts/provision-two-app-regs.sh (kept as fallback) -->

## Overview

This project uses **Azure Developer CLI (AZD)** + **Bicep** to provision:

| Resource | Module |
|---|---|
| Two Entra app registrations (repro + fixed) | `infra/modules/appRegistrations.bicep` |
| Two Entra service principals (repro + fixed) | `infra/modules/appRegistrations.bicep` |
| App Service `cloud-helper-fastmcp` (Python 3.12) | `infra/modules/appService.bicep` |
| Staging slot | `infra/modules/appService.bicep` |
| App Service Plan (S1, reused or new) | `infra/modules/appService.bicep` |

### Slot assignment (LOCKED — project directive 2026-05-09)

| Slot | App Registration | Redirect URIs |
|---|---|---|
| **production** | `cloud-helper-mcp-repro` | `http://localhost` only ← H1 bug preserved |
| **staging** | `cloud-helper-mcp-fixed` | `http://localhost` + `http://127.0.0.1` ← H1 fixed |

Sticky settings (`CLIENT_ID`, `AUDIENCE`, `RESOURCE_HOST`, `AZURE_TENANT_ID`) ensure a slot swap **never** silently changes which app registration is active.

---

## Prerequisites

```bash
# Check versions (min: AZD 1.9+, Bicep 0.26+, az CLI 2.60+)
azd version
az bicep version
az version
```

### Entra permissions required

The user (or service principal) running `azd provision` must have:

- **Application.ReadWrite.OwnedBy** on Microsoft Graph (to create and own app registrations)
- **Contributor** on the target resource group for the selected azd environment

If you get a `Application.ReadWrite.All` permission error during provisioning, your admin needs to grant your account the **Application Developer** or **Application Administrator** role in Entra.

---

## One-time setup

```bash
# 1. Authenticate with AZD (opens browser)
azd auth login

# 2. Create/select an AZD environment
azd env new <env-name>

# 3. Set the target Azure subscription + region
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION        eastus
azd env set AZURE_RESOURCE_GROUP  <new-resource-group>

# 4. Pick a globally unique App Service name for this environment
azd env set WEB_APP_NAME          <new-web-app-name>

# 5. (OPTIONAL) Reuse an existing App Service Plan in the target region.
#    If omitted, a new S1 plan is created.
azd env set EXISTING_PLAN_NAME    <existing-plan-name>
```

---

## Direct-Entra parallel environment (recommended)

Use a separate azd environment + resource group so the direct-Entra rollout stays isolated from any legacy deployment.

```bash
azd env new mcp-auth-test-direct
azd env set AZURE_SUBSCRIPTION_ID <your-subscription-id>
azd env set AZURE_LOCATION eastus
azd env set AZURE_RESOURCE_GROUP rg-mcp-auth-test-direct
azd env set AZURE_TENANT_ID <your-tenant-id>
azd env set WEB_APP_NAME <your-app-name>
azd env set EXISTING_PLAN_NAME ""
```

What changes automatically in the new environment:
- Entra app registrations are already parameterized by `environmentName`, so this env creates `cloud-helper-mcp-repro-mcp-auth-test-direct` and `cloud-helper-mcp-fixed-mcp-auth-test-direct`.
- Bicep also creates the matching tenant-local service principals, so no post-provision hook is needed.
- The web app name now comes from `WEB_APP_NAME`, so the direct-Entra deployment can use its own App Service hostname.
- `azure.yaml` does not pin a single App Service resource name, so `azd deploy` follows the resource tagged for the selected environment.

Manual steps before `azd up`:
- Confirm the chosen `WEB_APP_NAME` is globally unique.
- Make sure your Azure login is pointed at subscription `<your-subscription-id>`.
- Do **not** put any client secrets in the azd env; this deployment path is direct-Entra and should stay secret-free.

Manual steps after `azd up`:
- If your tenant requires it, grant/admin-consent the app registrations created for the new environment.
- Verify the generated outputs with `azd env get-values`; `ENTRA_APP_CLIENT_ID`, `ENTRA_APP_AUDIENCE`, and `WEB_APP_NAME` should all reflect the new environment.
- If you want local helper files such as `client/.env`, generate them from `azd env get-values` on demand instead of relying on AZD hooks.

## Provision infrastructure (Bicep)

```bash
# Deploy all Bicep templates — creates app regs + App Service + slots
azd provision
```

On success, AZD prints the output values. You can also retrieve them later:

```bash
azd env get-values
```

---

## Deploy app code

```bash
# Select the target environment, then deploy the FastMCP Python server
azd env select <env-name>
azd deploy
```

AZD discovers the correct App Service via the `azd-service-name: server` tag set in Bicep.

---

## Optional: Post-provision identifierUris fix

The MS Graph Bicep extension cannot set `identifierUris` to `api://{appId}` in the same resource block (self-referential). Bicep therefore uses an environment-specific display-name URI such as `api://cloud-helper-mcp-<env>` instead.

If you need the canonical `api://{appId}` format, run after provisioning:

```bash
eval "$(azd env get-values | sed 's/^/export /')"
APP_ID="$ENTRA_APP_CLIENT_ID"

az ad app update --id "$APP_ID" --identifier-uris "api://${APP_ID}"

# Then update the AUDIENCE sticky setting on the App Service
az webapp config appsettings set \
  --name "$WEB_APP_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --slot-settings "AUDIENCE=api://${APP_ID}/mcp.access"
```

---

## Full direct-Entra deploy flow

```bash
azd env select mcp-auth-test-direct
azd up
```

## Teardown

```bash
azd down
```

> ⚠️ This deletes the App Service but does **not** delete the Entra app registration. Delete it manually via the Azure Portal or:
> ```bash
> az ad app delete --id <ENTRA_APP_CLIENT_ID>
> ```

---

## Fallback: bash script

`scripts/provision-two-app-regs.sh` remains available as a fallback. It uses `az` CLI instead of Bicep and covers the same provisioning steps. See `scripts/README.md` for usage.
