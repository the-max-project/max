# Makefile for managing Docker Compose environments

GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
GIT_HASH   := $(shell git rev-parse --short HEAD)
export APP_VERSION := $(GIT_BRANCH)-$(GIT_HASH)

# Read feature flags from .env files
DEV_ENABLE_GPU := $(shell grep -m1 '^ENABLE_GPU=' .env.dev 2>/dev/null | cut -d= -f2)
DEV_ENABLE_LOGGING := $(shell grep -m1 '^ENABLE_LOGGING=' .env.dev 2>/dev/null | cut -d= -f2)
PROD_ENABLE_GPU := $(shell grep -m1 '^ENABLE_GPU=' .env 2>/dev/null | cut -d= -f2)
PROD_ENABLE_LOGGING := $(shell grep -m1 '^ENABLE_LOGGING=' .env 2>/dev/null | cut -d= -f2)

# Expand feature flags to compose override files
DEV_FLAGS = $(if $(filter true,$(DEV_ENABLE_GPU)),-f docker-compose.gpu.yaml) $(if $(filter true,$(DEV_ENABLE_LOGGING)),-f docker-compose.logging.yaml --profile logging)
PROD_FLAGS = $(if $(filter true,$(PROD_ENABLE_GPU)),-f docker-compose.gpu.yaml) $(if $(filter true,$(PROD_ENABLE_LOGGING)),-f docker-compose.logging.yaml --profile logging)

# Base compose commands
DEV_COMPOSE = docker compose --env-file .env.dev -f docker-compose.yaml -f docker-compose.dev.yaml $(DEV_FLAGS)
PROD_COMPOSE = docker compose --env-file .env -f docker-compose.yaml --profile shared $(PROD_FLAGS)
SHARED_COMPOSE = docker compose --env-file .env.dev -f docker-compose.yaml --profile shared $(if $(filter true,$(DEV_ENABLE_GPU)),-f docker-compose.gpu.yaml)

# --- Development Commands ---

echo:
	@echo "APP_VERSION   = $(APP_VERSION)"
	@echo "DEV CMD       = $(DEV_COMPOSE)"
	@echo "PROD CMD      = $(PROD_COMPOSE)"
	@echo "SHARED CMD    = $(SHARED_COMPOSE)"

shared:
	$(SHARED_COMPOSE) up -d --no-recreate ollama neo4j

shared-build:
	$(SHARED_COMPOSE) up --build --detach

shared-down:
	$(SHARED_COMPOSE) down

## Build and start the development containers
dev: shared
	$(DEV_COMPOSE) up

dev-build:
	$(DEV_COMPOSE) build

dev-rebuild:
	$(DEV_COMPOSE) build --no-cache

## Stop the development containers
dev-down:
	$(DEV_COMPOSE) down

# --- macOS Development (native STT) ---

macos-stt:
	@echo "Starting native macOS STT service..."
	@bash services/max-stt/scripts/run_native_macos.sh &

dev-macos: macos-stt shared
	@echo "Launching dev containers (STT running natively on macOS)..."
	$(DEV_COMPOSE) --profile shared up --scale stt=0

# --- Production Commands ---

## Build and start the production containers in detached mode
prod:
	$(PROD_COMPOSE) up -d

prod-build:
	$(PROD_COMPOSE) build

prod-rebuild:
	$(PROD_COMPOSE) build --no-cache

## Stop the production containers
prod-down:
	$(PROD_COMPOSE) down

logs:
	docker logs -f

logs-ui:
	@echo "---"
	@echo "Starting Grafana and Loki services..."
	@echo "Access Grafana at: http://localhost:3000"
	@echo "---"
	$(PROD_COMPOSE) up -d loki grafana

# --- Utility Commands ---

## Stop all containers and remove volumes (cleans the cache)
clean:
	$(DEV_COMPOSE) down -v
	$(PROD_COMPOSE) down -v
	$(SHARED_COMPOSE) down -v

.PHONY: dev dev-down dev-build prod prod-down clean shared shared-down macos-stt dev-macos echo logs logs-ui a-test