# Multi-stage Dockerfile for the FastMCP OAuth server
#
# Build:
#   docker build -t mcp-oauth:local .
#
# Run locally:
#   docker run --rm -p 8000:8000 \
#     -e TENANT_ID="<tenant-id>" \
#     -e CLIENT_ID="<client-id>" \
#     -e RESOURCE_HOST="localhost:8000" \
#     mcp-oauth:local

# ----------------------------------------------------------------------------
# Build stage
# ----------------------------------------------------------------------------
FROM python:3.12-slim AS build

ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:$PATH"

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && python -m venv /opt/venv \
    && pip install --no-cache-dir --upgrade pip setuptools wheel

WORKDIR /build/server
COPY server/pyproject.toml server/requirements.txt ./
COPY server/*.py ./
RUN pip install --no-cache-dir -r requirements.txt

# ----------------------------------------------------------------------------
# Runtime stage
# ----------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8000 \
    PYTHONUNBUFFERED=1

RUN groupadd --system app \
    && useradd --system --gid app --create-home --home-dir /home/app --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY --chown=app:app server/*.py ./

USER app

EXPOSE 8000

# Note: no Dockerfile HEALTHCHECK on purpose. Use the orchestrator's native
# readiness/liveness probes so probe policy stays with the runtime platform.

CMD ["sh", "-c", "exec python -m uvicorn server:app --host 0.0.0.0 --port ${PORT:-8000} --proxy-headers"]
