.DEFAULT_GOAL := help
MAKEFLAGS     += --no-print-directory
SHELL         := /bin/bash

# -- Colors ---------------------------------------------------
BOLD   := \033[1m
GREEN  := \033[32m
CYAN   := \033[36m
RED    := \033[31m
YELLOW := \033[33m
RESET  := \033[0m

# -- Image & Build Config -------------------------------------
REGISTRY   ?= ghcr.io
IMAGE_REPO := rondomondo/screenshot
REMOTE     := $(REGISTRY)/$(IMAGE_REPO)
VERSION     = $(shell cat VERSION 2>/dev/null | tr -d '[:space:]')
PLATFORMS  := linux/amd64,linux/arm64
BUILDER    := screenshotter-builder
NO_CACHE   ?= 1
_CACHE_FLAG = $(if $(filter 1,$(NO_CACHE)),--no-cache,)

# -- Paths & Directory Defaults -------------------------------
SCREENSHOTS_DIR ?= $(CURDIR)/screenshots
PDFS_DIR        ?= $(CURDIR)/pdfs
HTML_DIR        ?= $(CURDIR)/html
WORKSPACE_DIR   ?= $(CURDIR)/workspace
SESSIONS_DIR    := $(WORKSPACE_DIR)/sessions

SESSION         ?= default
SESSION_FILE    := $(SESSIONS_DIR)/$(SESSION).json

# -- Help -----------------------------------------------------
.PHONY: help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n"} \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0,5) } \
	  /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)

##@ Build

.PHONY: build
build: ## Build single-arch image for local testing (loads into Docker daemon). NO_CACHE=1 to bust cache.
	docker build $(_CACHE_FLAG) -t $(REMOTE):$(VERSION) -t $(REMOTE):latest .
	@printf "$(GREEN)Built$(RESET) $(REMOTE):$(VERSION) and $(REMOTE):latest (local arch only)\n"

.PHONY: builder-init
builder-init: ## Create/reuse the multi-platform buildx builder
	@if ! docker buildx inspect $(BUILDER) >/dev/null 2>&1; then \
	  docker buildx create --name $(BUILDER) --driver docker-container --bootstrap; \
	  printf "$(GREEN)Created$(RESET) buildx builder: $(BUILDER)\n"; \
	else \
	  printf "$(CYAN)Reusing$(RESET) buildx builder: $(BUILDER)\n"; \
	fi

##@ Release

.PHONY: bump
bump: ## Increment patch version in VERSION file
	@old=$(VERSION); \
	new=$$(awk -F. '{printf "%d.%d.%d", $$1, $$2, $$3+1}' VERSION); \
	echo "$$new" > VERSION; \
	printf "$(GREEN)Bumped$(RESET) $$old -> $$new\n"

.PHONY: push
push: builder-init ## Build multi-platform image and push to ghcr.io (amd64 + arm64). NO_CACHE=1 to bust cache.
	docker buildx build \
	  --builder $(BUILDER) \
	  $(_CACHE_FLAG) \
	  --platform $(PLATFORMS) \
	  --tag $(REMOTE):$(VERSION) \
	  --tag $(REMOTE):latest \
	  --push \
	  .
	@printf "$(GREEN)Pushed$(RESET) $(REMOTE):$(VERSION) and $(REMOTE):latest ($(PLATFORMS))\n"

.PHONY: release
release: bump push ## Bump patch version, build multi-platform, and push to ghcr.io

##@ Install

DESTDIR ?= /usr/local/bin

.PHONY: install
install: ## Install url2pdf and url2image to DESTDIR (default: /usr/local/bin)
	@install -m 755 url2capture.sh $(DESTDIR)/url2capture
	@printf "$(GREEN)Installed$(RESET) $(DESTDIR)/url2capture\n"
	@ln -sf $(DESTDIR)/url2capture $(DESTDIR)/url2pdf
	@printf "$(GREEN)Linked$(RESET)     $(DESTDIR)/url2pdf -> $(DESTDIR)/url2capture\n"
	@ln -sf $(DESTDIR)/url2capture $(DESTDIR)/url2image
	@printf "$(GREEN)Linked$(RESET)     $(DESTDIR)/url2image -> $(DESTDIR)/url2capture\n"

.PHONY: uninstall
uninstall: ## Remove url2pdf, url2image, and url2capture from DESTDIR
	@for name in url2pdf url2image url2capture; do \
	  if [ -f "$(DESTDIR)/$$name" ] || [ -L "$(DESTDIR)/$$name" ]; then \
	    rm -f "$(DESTDIR)/$$name" && printf "$(GREEN)Removed$(RESET)   $(DESTDIR)/$$name\n"; \
	  else \
	    printf "$(YELLOW)Not found$(RESET) $(DESTDIR)/$$name\n"; \
	  fi; \
	done

##@ Test

.PHONY: test
test: ## Run the unit test suite
	uv run pytest

##@ Dev Operations

# Helper definition: Checks if MCP server is running via JSON-RPC ping; if not, starts it temporarily.
define RUN_MCP_CLIENT
	@mkdir -p "$(SCREENSHOTS_DIR)" "$(PDFS_DIR)" "$(HTML_DIR)" "$(SESSIONS_DIR)"
	@WAS_RUNNING=1; \
	if ! curl -fs --max-time 3 -X POST -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
	   -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1"}}}' \
	   http://localhost:3000/mcp >/dev/null 2>&1; then \
		WAS_RUNNING=0; \
		printf "$(CYAN)MCP server not detected. Spinning up background container...$(RESET)\n"; \
		$(MAKE) mcp-up SESSION=$(SESSION) >/dev/null; \
	fi; \
	uv run ssc.py $(1) $(TARGET) $(ARGS); \
	EXIT_CODE=$$?; \
	if [ "$$WAS_RUNNING" -eq 0 ]; then \
		printf "$(CYAN)Cleaning up temporary MCP container...$(RESET)\n"; \
		$(MAKE) mcp-down SESSION=$(SESSION) >/dev/null; \
	fi; \
	exit $$EXIT_CODE
endef

.PHONY: screenshot
screenshot: ## Take a full-page screenshot using the MCP engine: make screenshot TARGET=https://en.wikipedia.org/wiki/Special:Random [ARGS="--no-scroll"]
	@if [ -z "$(TARGET)" ]; then \
		printf "$(RED)Error: TARGET is required. Usage: make screenshot TARGET=https://en.wikipedia.org/wiki/Special:Random$(RESET)\n"; \
		exit 1; \
	fi
	$(call RUN_MCP_CLIENT,screenshot)

.PHONY: pdf
pdf: ## Save page as PDF using screen colors & DOM readiness: make pdf TARGET=https://en.wikipedia.org/wiki/Special:Random [ARGS="--pause 1000"]
	@if [ -z "$(TARGET)" ]; then \
		printf "$(RED)Error: TARGET is required. Usage: make pdf TARGET=https://en.wikipedia.org/wiki/Special:Random$(RESET)\n"; \
		exit 1; \
	fi
	$(call RUN_MCP_CLIENT,pdf)

.PHONY: mcp-up
mcp-up: ## Start the MCP server in the background (SESSION=default selects the browser session to load)
	@mkdir -p "$(SESSIONS_DIR)"
	@if [ ! -f "$(SESSION_FILE)" ]; then \
	  printf '{}' > "$(SESSION_FILE)"; \
	  printf "$(CYAN)Created$(RESET) empty session: $(SESSION_FILE)\n"; \
	fi
	SESSION=$(SESSION) docker compose up -d mcp
	@printf "$(GREEN)Started$(RESET) MCP server on port 3000 (session: $(SESSION))\n"

.PHONY: mcp-down
mcp-down: ## Stop and remove the MCP server container
	SESSION=$(SESSION) docker compose down mcp
	@printf "$(GREEN)Stopped$(RESET) MCP server\n"

.PHONY: mcp-shell
mcp-shell: ## Open a shell in the MCP container (useful for inspecting /workspace)
	@mkdir -p "$(SESSIONS_DIR)"
	docker run --rm -it \
	  -v $(WORKSPACE_DIR):/workspace \
	  --entrypoint bash \
	  $(REMOTE):latest

.PHONY: docker-shell
docker-shell: ## Open an interactive bash shell in the image
	docker run --rm -it --entrypoint bash $(REMOTE):latest

##@ Info

.PHONY: status
status: ## Show running containers, health, and MCP connection details
	@echo ""
	@printf "$(BOLD)Containers$(RESET)\n"
	@docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
	@echo ""
	@if docker compose ps --status running 2>/dev/null | grep -q "mcp"; then \
	  printf "$(BOLD)MCP server$(RESET)\n"; \
	  printf "  HTTP/SSE endpoint : $(GREEN)http://localhost:3000$(RESET)\n"; \
	  printf "  Health check      : "; \
	  if curl -fs --max-time 3 -X POST -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
	     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1"}}}' \
	     http://localhost:3000/mcp >/dev/null 2>&1; then \
	    printf "$(GREEN)healthy$(RESET)\n"; \
	  else \
	    printf "$(RED)unreachable$(RESET)\n"; \
	  fi; \
	  printf "  Session file      : $(SESSION_FILE)\n"; \
	  printf "  MCP endpoint      : http://localhost:3000/mcp\n"; \
	  printf "  SSE endpoint      : http://localhost:3000/sse (legacy)\n"; \
	fi
	@echo ""

.PHONY: size
size: ## Show local image sizes
	@docker images $(REMOTE) --format "table {{.Tag}}\t{{.Size}}\t{{.ID}}" | head -10

.PHONY: version
version: ## Print current version
	@echo $(VERSION)

.PHONY: inspect
inspect: ## Show manifest platforms for the remote :latest image
	docker buildx imagetools inspect $(REMOTE):latest

##@ Cleanup

.PHONY: clean
clean: ## Remove local image tags for this image
	@for tag in "$(REMOTE):$(VERSION)" "$(REMOTE):latest"; do \
	  if docker image inspect "$$tag" >/dev/null 2>&1; then \
	    docker rmi "$$tag" && printf "$(GREEN)Removed$(RESET) $$tag\n"; \
	  else \
	    printf "$(YELLOW)Not found$(RESET)  $$tag\n"; \
	  fi; \
	done

.PHONY: clean-builder
clean-builder: ## Remove the buildx builder instance
	@docker buildx rm $(BUILDER) 2>/dev/null && \
	  printf "$(GREEN)Removed$(RESET) builder: $(BUILDER)\n" || \
	  printf "$(YELLOW)Not found$(RESET)  builder: $(BUILDER)\n"

.PHONY: clean-generated
clean-generated: ## Empty screenshots/ and pdfs/ output directories
	@rm -rf "$(SCREENSHOTS_DIR)"/* "$(PDFS_DIR)"/*
	@printf "$(GREEN)Cleared$(RESET) $(SCREENSHOTS_DIR) and $(PDFS_DIR)\n"

.PHONY: clean-python
clean-python: ## Remove __pycache__, *.pyc, *.pyo, .mypy_cache, .pytest_cache, .ruff_cache
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@find . -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete 2>/dev/null || true
	@rm -rf .mypy_cache .pytest_cache .ruff_cache
	@printf "$(GREEN)Removed$(RESET) Python caches\n"

.PHONY: clean-node
clean-node: ## Remove all node_modules directories recursively
	@find . -type d -name "node_modules" -exec rm -rf {} + 2>/dev/null || true
	@printf "$(GREEN)Removed$(RESET) node_modules\n"

.PHONY: clean-all
clean-all: clean clean-builder clean-generated clean-python clean-node ## Run all clean targets