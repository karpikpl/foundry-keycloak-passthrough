.PHONY: install dev run-uvx client-install client-run

install:
	cd server && uv sync

dev:
	cd server && uv run python server.py

run-uvx:
	uvx --from ./server cloud-helper-fastmcp

client-install:
	cd client && uv sync

client-run:
	cd client && uv run test_client.py $(TARGET)
