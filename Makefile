# Makefile for managing Docker Compose environments

GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
GIT_HASH   := $(shell git rev-parse --short HEAD)
export APP_VERSION := $(GIT_BRANCH)-$(GIT_HASH)

# --- Platform Detection ---
UNAME_S  := $(shell uname -s)
IS_MACOS := $(if $(filter Darwin,$(UNAME_S)),true,false)

# --- Read Feature Flags from .env files ---
DEV_ENABLE_GPU     := $(shell grep -m1 '^ENABLE_GPU=' .env.dev 2>/dev/null | cut -d= -f2)
DEV_ENABLE_LOGGING := $(shell grep -m1 '^ENABLE_LOGGING=' .env.dev 2>/dev/null | cut -d= -f2)
PROD_ENABLE_GPU    := $(shell grep -m1 '^ENABLE_GPU=' .env 2>/dev/null | cut -d= -f2)
PROD_ENABLE_LOGGING:= $(shell grep -m1 '^ENABLE_LOGGING=' .env 2>/dev/null | cut -d= -f2)

# --- Compose Overrides & Flags ---
DEV_FLAGS  = $(if $(filter true,$(DEV_ENABLE_GPU)),-f docker-compose.gpu.yaml) \
             $(if $(filter true,$(DEV_ENABLE_LOGGING)),-f docker-compose.logging.yaml --profile logging)

PROD_FLAGS = $(if $(filter true,$(PROD_ENABLE_GPU)),-f docker-compose.gpu.yaml) \
             $(if $(filter true,$(PROD_ENABLE_LOGGING)),-f docker-compose.logging.yaml --profile logging)

# --- Base Compose Commands ---
DEV_COMPOSE          = docker compose --env-file .env.dev -f docker-compose.yaml -f docker-compose.dev.yaml $(DEV_FLAGS)
DEV_SHARED_COMPOSE   = docker compose --env-file .env.dev -f docker-compose.yaml --profile shared $(if $(filter true,$(DEV_ENABLE_GPU)),-f docker-compose.gpu.yaml)

PROD_COMPOSE         = docker compose --env-file .env -f docker-compose.yaml --profile shared $(PROD_FLAGS)
PROD_SHARED_COMPOSE  = docker compose --env-file .env -f docker-compose.yaml --profile shared $(if $(filter true,$(PROD_ENABLE_GPU)),-f docker-compose.gpu.yaml)
PROD_MACOS_CORE      = docker compose --env-file .env -f docker-compose.yaml $(PROD_FLAGS)


# ==============================================================================
# INDIVIDUAL SERVICE TARGETS (Development Focus)
# ==============================================================================

ollama:
ifeq ($(IS_MACOS),true)
	@echo "Opening native Ollama in a new Terminal window..."
	@pgrep -x "ollama" >/dev/null || osascript -e 'tell application "Terminal" to do script "ollama serve"'
else
	$(DEV_SHARED_COMPOSE) up -d --no-recreate ollama
endif

stt:
ifeq ($(IS_MACOS),true)
	@echo "Opening native STT in a new Terminal window..."
	@pgrep -f "services/max-stt" >/dev/null || osascript -e 'tell application "Terminal" to do script "cd $(CURDIR) && bash services/max-stt/scripts/run_native_macos.sh"'
else
	$(DEV_COMPOSE) up -d stt
endif

tts:
	$(DEV_COMPOSE) up -d tts

assistant:
	$(DEV_COMPOSE) up -d assistant

proxy:
	$(DEV_COMPOSE) up -d proxy

neo4j:
	$(DEV_SHARED_COMPOSE) up -d --no-recreate neo4j


# ==============================================================================
# DEVELOPMENT WORKFLOWS
# ==============================================================================

## Pre-boot shared/persistent containers (Ollama + Neo4j)
shared: ollama neo4j

shared-build:
	$(DEV_SHARED_COMPOSE) up --build --detach ollama neo4j

shared-down:
	$(DEV_SHARED_COMPOSE) down

## Start the development environment
dev: shared stt tts assistant proxy
	@echo "--- All development services started ---"
	$(DEV_COMPOSE) logs -f assistant

dev-build:
	$(DEV_COMPOSE) build

dev-rebuild:
	$(DEV_COMPOSE) build --no-cache

## Stop the dev environment (Docker dev services + Mac background processes)
dev-down:
	$(DEV_COMPOSE) down
ifeq ($(IS_MACOS),true)
	@echo "Terminating native development background processes..."
	@-pkill -f "services/max-stt" 2>/dev/null || true
endif


# ==============================================================================
# PRODUCTION WORKFLOWS
# ==============================================================================

## Standard Linux / Server full-stack production start (All in Docker)
prod:
	$(PROD_COMPOSE) up -d

prod-build:
	$(PROD_COMPOSE) build

prod-rebuild:
	$(PROD_COMPOSE) build --no-cache

prod-down:
	$(PROD_COMPOSE) down

## macOS Production: Native Metal acceleration for Ollama & STT + Docker for core services
prod-macos:
	@echo "Ensuring native macOS Ollama is active..."
	@pgrep -x "ollama" >/dev/null || (ollama serve >/dev/null 2>&1 &)
	@echo "Starting native macOS STT daemon..."
	@pgrep -f "services/max-stt" >/dev/null || (nohup bash services/max-stt/scripts/run_native_macos.sh >/dev/null 2>&1 &)
	@echo "Starting persistent production database (Neo4j)..."
	$(PROD_SHARED_COMPOSE) up -d --no-recreate neo4j
	@echo "Starting production core services (TTS, Assistant, Proxy)..."
	$(PROD_MACOS_CORE) up -d tts assistant proxy

prod-macos-down:
	@echo "Stopping production Docker containers..."
	$(PROD_MACOS_CORE) down
	$(PROD_SHARED_COMPOSE) down
	@echo "Stopping native background processes..."
	@-pkill -f "services/max-stt" 2>/dev/null || true


# ==============================================================================
# UTILITY COMMANDS
# ==============================================================================

echo:
	@echo "APP_VERSION         = $(APP_VERSION)"
	@echo "IS_MACOS            = $(IS_MACOS)"
	@echo "DEV_COMPOSE         = $(DEV_COMPOSE)"
	@echo "DEV_SHARED_COMPOSE  = $(DEV_SHARED_COMPOSE)"
	@echo "PROD_COMPOSE        = $(PROD_COMPOSE)"
	@echo "PROD_MACOS_CORE     = $(PROD_MACOS_CORE)"

logs:
	docker logs -f

logs-ui:
	@echo "Access Grafana at: http://localhost:3000"
	$(PROD_COMPOSE) up -d loki grafana

## Stop all containers across environments and remove local volumes
clean:
	$(DEV_COMPOSE) down -v
	$(PROD_COMPOSE) down -v
	$(DEV_SHARED_COMPOSE) down -v
ifeq ($(IS_MACOS),true)
	@-pkill -f "services/max-stt" 2>/dev/null || true
endif

.PHONY: ollama neo4j stt tts assistant proxy \
        shared shared-build shared-down \
        dev dev-build dev-rebuild dev-down \
        prod prod-build prod-rebuild prod-down \
        prod-macos prod-macos-down \
        echo logs logs-ui clean