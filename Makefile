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
#PLATFORMS  := linux/amd64
BUILDER    := screenshotter-builder
NO_CACHE   ?= 0
_CACHE_FLAG = $(if $(filter 1,$(NO_CACHE)),--no-cache,)

# -- Paths & Directory Defaults -------------------------------
SCREENSHOTS_DIR ?= $(CURDIR)/screenshots
PDFS_DIR        ?= $(CURDIR)/pdfs
HTML_DIR        ?= $(CURDIR)/html
WORKSPACE_DIR   ?= $(CURDIR)/workspace
SESSIONS_DIR    := $(WORKSPACE_DIR)/sessions

SESSION         ?= default
SESSION_FILE    := $(SESSIONS_DIR)/$(SESSION).json

#EXAMPLE_URL     ?= https://en.wikipedia.org/wiki/Special:Random
EXAMPLE_URL     ?= https://jax-ml.github.io/scaling-book/index

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
	docker build $(_CACHE_FLAG) --build-arg SCREENSHOT_VERSION=$(VERSION) -t $(REMOTE):$(VERSION) -t $(REMOTE):latest .
	@printf "$(GREEN)Built$(RESET) $(REMOTE):$(VERSION) and $(REMOTE):latest (local arch only)\n"

.PHONY: build-slim
build-slim: ## Build slim variant (system Chromium, no SRE tools). NO_CACHE=1 to bust cache.
	docker build $(_CACHE_FLAG) --build-arg SCREENSHOT_VERSION=$(VERSION) -f Dockerfile.slim -t $(REMOTE):$(VERSION)-slim -t $(REMOTE):slim .
	@printf "$(GREEN)Built$(RESET) $(REMOTE):$(VERSION)-slim and $(REMOTE):slim\n"

.PHONY: build-pw
build-pw: ## Build Playwright-official-base variant. NO_CACHE=1 to bust cache.
	docker build $(_CACHE_FLAG) --build-arg SCREENSHOT_VERSION=$(VERSION) -f Dockerfile.pw -t $(REMOTE):$(VERSION)-pw -t $(REMOTE):pw .
	@printf "$(GREEN)Built$(RESET) $(REMOTE):$(VERSION)-pw and $(REMOTE):pw\n"

.PHONY: build-sre
build-sre: ## Build standalone SRE tools image (curl, dig, ss, strace, htop, jq, etc). NO_CACHE=1 to bust cache.
	docker build $(_CACHE_FLAG) -f Dockerfile.sre -t $(REGISTRY)/rondomondo/sre-tools:latest .
	@printf "$(GREEN)Built$(RESET) $(REGISTRY)/rondomondo/sre-tools:latest\n"

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
	  --build-arg SCREENSHOT_VERSION=$(VERSION) \
	  --platform $(PLATFORMS) \
	  --tag $(REMOTE):$(VERSION) \
	  --tag $(REMOTE):latest \
	  --tag $(REMOTE):find4 \
	  --push \
	  .
	@printf "$(GREEN)Pushed$(RESET) $(REMOTE):$(VERSION) and $(REMOTE):latest ($(PLATFORMS))\n"

.PHONY: release
release: bump push ## Bump patch version, build multi-platform, and push to ghcr.io

.PHONY: retag
retag: ## Re-tag an existing remote image without pulling: make retag FROM=latest TAG=v0.1.1
	@if [ -z "$(FROM)" ] || [ -z "$(TAG)" ]; then \
	  printf "$(RED)Error: FROM and TAG are required. Usage: make retag FROM=latest TAG=v0.1.1$(RESET)\n"; \
	  exit 1; \
	fi
	docker buildx imagetools create -t $(REMOTE):$(TAG) $(REMOTE):$(FROM)
	@printf "$(GREEN)Retagged$(RESET) $(REMOTE):$(FROM) -> $(REMOTE):$(TAG)\n"

##@ Install

.PHONY: install
install: ## Install url2pdf and url2image; tries /usr/local/bin, falls back to ~/.local/bin
	@if install -m 755 url2capture.sh /usr/local/bin/url2capture 2>/dev/null; then \
	  IDIR=/usr/local/bin; \
	else \
	  mkdir -p ~/.local/bin; \
	  install -m 755 url2capture.sh ~/.local/bin/url2capture; \
	  IDIR=~/.local/bin; \
	fi; \
	printf "$(GREEN)Installed$(RESET) $$IDIR/url2capture\n"; \
	ln -sf $$IDIR/url2capture $$IDIR/url2pdf; \
	printf "$(GREEN)Linked$(RESET)     $$IDIR/url2pdf -> $$IDIR/url2capture\n"; \
	ln -sf $$IDIR/url2capture $$IDIR/url2image; \
	printf "$(GREEN)Linked$(RESET)     $$IDIR/url2image -> $$IDIR/url2capture\n"

.PHONY: uninstall
uninstall: ## Remove url2pdf, url2image, and url2capture from /usr/local/bin and ~/.local/bin
	@for dir in /usr/local/bin ~/.local/bin; do \
	  for name in url2pdf url2image url2capture; do \
	    if [ -f "$$dir/$$name" ] || [ -L "$$dir/$$name" ]; then \
	      rm -f "$$dir/$$name" && printf "$(GREEN)Removed$(RESET)   $$dir/$$name\n"; \
	    fi; \
	  done; \
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
	uv run ssc.py $(1) --url http://localhost:3000/sse $(TARGET) $(ARGS); \
	EXIT_CODE=$$?; \
	if [ "$$WAS_RUNNING" -eq 0 ]; then \
		printf "$(CYAN)Cleaning up temporary MCP container...$(RESET)\n"; \
		$(MAKE) mcp-down SESSION=$(SESSION) >/dev/null; \
	fi; \
	exit $$EXIT_CODE
endef

.PHONY: screenshot
screenshot: ## Take a full-page screenshot (defaults to EXAMPLE_URL): make screenshot [TARGET=https://...] [ARGS="--no-scroll"]
	$(eval TARGET ?= $(EXAMPLE_URL))
	$(call RUN_MCP_CLIENT,screenshot)

.PHONY: pdf
pdf: ## Save page as PDF (defaults to EXAMPLE_URL): make pdf [TARGET=https://...] [ARGS="--pause 1000"]
	$(eval TARGET ?= $(EXAMPLE_URL))
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
	docker run --rm -it --entrypoint bash $(REMOTE):$(VERSION)

##@ Info

.PHONY: examples
examples: ## Print cut-and-paste usage examples
	@printf "\n$(BOLD)Install onto your host$(RESET)\n"
	@printf "  docker run --rm $(REMOTE):latest install | sh\n"
	@printf "  docker run --rm $(REMOTE):latest uninstall | sh\n"
	@printf "\n$(BOLD)url2image / url2pdf (after install)$(RESET)\n"
	@printf "  url2image $(EXAMPLE_URL)\n"
	@printf "  url2image $(EXAMPLE_URL) --convert webp\n"
	@printf "  url2image $(EXAMPLE_URL) --no-scroll --viewport-size 1920x1080\n"
	@printf "  url2pdf   $(EXAMPLE_URL)\n"
	@printf "  url2pdf   $(EXAMPLE_URL) --convert jpeg\n"
	@printf "  url2pdf   $(EXAMPLE_URL) --paper-format Letter --wait-for-timeout 5000\n"
	@printf "  DEBUG=1   url2pdf $(EXAMPLE_URL)\n"
	@printf "\n$(BOLD)Docker directly$(RESET)\n"
	@printf "  docker run --rm \\\\\n"
	@printf "    -v \$$(pwd)/screenshots:/screenshots \\\\\n"
	@printf "    -v \$$(pwd)/pdfs:/pdfs \\\\\n"
	@printf "    $(REMOTE):latest screenshot $(EXAMPLE_URL)\n"
	@printf "  docker run --rm \\\\\n"
	@printf "    -v \$$(pwd)/screenshots:/screenshots \\\\\n"
	@printf "    -v \$$(pwd)/pdfs:/pdfs \\\\\n"
	@printf "    -v \$$(pwd)/html:/html:ro \\\\\n"
	@printf "    $(REMOTE):latest screenshot my-page.html\n"
	@printf "\n$(BOLD)make screenshot / make pdf (via MCP client)$(RESET)\n"
	@printf "  make screenshot TARGET=$(EXAMPLE_URL)\n"
	@printf "  make screenshot TARGET=$(EXAMPLE_URL) ARGS=\"--convert webp\"\n"
	@printf "  make screenshot TARGET=my-page.html\n"
	@printf "  make pdf        TARGET=$(EXAMPLE_URL)\n"
	@printf "  make pdf        TARGET=$(EXAMPLE_URL) ARGS=\"--paper-format Letter\"\n"
	@printf "\n$(BOLD)MCP server$(RESET)\n"
	@printf "  make mcp-up\n"
	@printf "  make mcp-up SESSION=mysite\n"
	@printf "  make mcp-down\n"
	@printf "  make status\n"
	@printf "\n"

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
	@rm -rf "$(SCREENSHOTS_DIR)"/* "$(PDFS_DIR)"/* "$(HTML_DIR)"/*.png "$(HTML_DIR)"/*.pdf
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