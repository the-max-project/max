# Makefile for managing Docker Compose environments

# Define the version
GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
GIT_HASH   := $(shell git rev-parse --short HEAD)
export APP_VERSION := $(GIT_BRANCH)-$(GIT_HASH)

# This silently searches the env files for 'GPU=1'. If found, the variable is populated.
DEV_HAS_GPU := $(shell grep -E '^GPU=1' .env.dev 2>/dev/null)
PROD_HAS_GPU := $(shell grep -E '^GPU=1' .env 2>/dev/null)

DEV_COMPOSE = docker compose --env-file .env.dev -f docker-compose.yaml -f docker-compose.dev.yaml
PROD_COMPOSE = docker compose --env-file .env -f docker-compose.yaml -f docker-compose.prod.yaml
SHARED_COMPOSE = docker compose -p shared-ai -f docker-compose.shared.yaml

# Always include logging for down cmds
DEV_COMPOSE_LOG = $(DEV_COMPOSE) -f docker-compose.logging.yaml
PROD_COMPOSE_LOG = $(PROD_COMPOSE) -f docker-compose.logging.yaml

# export LOG=1 to enable logging services
ifdef LOG
	DEV_COMPOSE += -f docker-compose.logging.yaml
	PROD_COMPOSE += -f docker-compose.logging.yaml
endif

# --- Hardware Overrides ---

# If .env.dev has GPU=1, append the main GPU compose file to dev commands
ifneq ($(DEV_HAS_GPU),)
	DEV_COMPOSE += -f docker-compose.gpu.yaml
endif

# If .env has GPU=1, append the main GPU compose file to prod commands
ifneq ($(PROD_HAS_GPU),)
	PROD_COMPOSE += -f docker-compose.gpu.yaml
endif

# If EITHER environment has GPU=1, append the shared GPU compose file to shared commands
ifneq ($(DEV_HAS_GPU)$(PROD_HAS_GPU),)
	SHARED_COMPOSE += -f docker-compose.shared.gpu.yaml
endif

# The shared stack (dockerized Ollama) only has services under the
# container-ollama profile. On local-only setups (e.g. macOS with native
# Ollama), skip it entirely -- otherwise Compose errors with "no service selected".
HAS_CONTAINER_OLLAMA := $(shell grep -E '^COMPOSE_PROFILES=.*container-ollama' .env .env.dev 2>/dev/null)

# Native STT (MLX on macOS) support -- mirrors the native-Ollama pattern above.
# See doc/dev-mac/LargeSttDelayPlan.md (Option 2).
DEV_STT_NATIVE := $(shell grep -E '^STT_MODE=native' .env.dev 2>/dev/null)

ifneq ($(DEV_STT_NATIVE),)
	DEV_COMPOSE += -f docker-compose.stt-native.yaml
endif

# --- Development Commands ---
echo:
	@echo "APP_VERSION   = " $(APP_VERSION)
	@echo "DEV CMD       = " $(DEV_COMPOSE)
	@echo "PROD CMD      = " $(PROD_COMPOSE)
	@echo "SHARED CMD    = " $(SHARED_COMPOSE)

shared:
ifneq ($(HAS_CONTAINER_OLLAMA),)
	$(SHARED_COMPOSE) up -d --no-recreate
else
	@echo "Skipping shared ollama container (COMPOSE_PROFILES=local-only) -- using native Ollama."
endif

shared-build:
	$(SHARED_COMPOSE) up --build --detach

shared-down:
	$(SHARED_COMPOSE) down

## Build and start the development containers
dev: shared
ifneq ($(DEV_STT_NATIVE),)
	@echo "STT_MODE=native detected -- run 'make stt-native' in a separate terminal before/while using the app."
endif
	$(DEV_COMPOSE) up

dev-build: shared
ifneq ($(DEV_STT_NATIVE),)
	@echo "STT_MODE=native detected -- run 'make stt-native' in a separate terminal before/while using the app."
endif
	$(DEV_COMPOSE) up --build

a-test:
	$(DEV_COMPOSE) up ollama neo4j --build

## Stop the development containers
dev-down:
	$(DEV_COMPOSE_LOG) down

## Run the STT service natively (MLX/Metal) -- required when STT_MODE=native in .env.dev
stt-native:
	set -a && . ./.env.dev && set +a && ./services/max-stt/scripts/run_native_macos.sh

# --- Production Commands ---

## Build and start the production containers in detached mode
prod: shared
	$(PROD_COMPOSE) up -d

prod-build: shared
	$(PROD_COMPOSE) up --build -d

## Stop the production containers
prod-down:
	$(PROD_COMPOSE_LOG) down

logs:
	docker logs -f

logs-ui:
	@echo "---"
	@echo "🔍 Starting Grafana and Loki services..."
	@echo "Access Grafana at: http://localhost:3000"
	@echo "---"
	$(PROD_COMPOSE) up -d loki grafana

# --- Utility Commands ---

## Stop all containers and remove volumes (cleans the cache)
clean:
	$(DEV_COMPOSE) down -v
	$(PROD_COMPOSE) down -v
	$(SHARED_COMPOSE) down -v

.PHONY: dev dev-down dev-shell prod prod-down clean stt-native
