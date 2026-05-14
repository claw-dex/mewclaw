.PHONY: build build-nocache up down logs

# Build all agents with a fresh CACHEBUST so the Claude installer re-runs.
# Pass SERVICE=codasst (or engagius/proximate) to build a single agent.
build:
	CACHEBUST=$$(date +%s) docker compose build $(SERVICE)

# Full --no-cache rebuild (slowest; use when you want everything redone).
build-nocache:
	CACHEBUST=$$(date +%s) docker compose build --no-cache $(SERVICE)

up:
	docker compose up -d $(SERVICE)

down:
	docker compose down

logs:
	docker compose logs -f $(SERVICE)
