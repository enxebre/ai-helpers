# Makefile for ai-helpers

# Container runtime (podman or docker)
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || echo docker)

# claudelint image
CLAUDELINT_IMAGE = ghcr.io/stbenjam/claudelint:main

# Detect if SELinux is enforcing and add security option
SELINUX_OPT := $(shell if command -v getenforce >/dev/null 2>&1 && [ "$$(getenforce 2>/dev/null)" = "Enforcing" ]; then echo "--security-opt label=disable"; fi)

.PHONY: help
help: ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: lint
lint: ## Run plugin linter (verbose, strict mode)
	@echo "Running claudelint with $(CONTAINER_RUNTIME)..."
	$(CONTAINER_RUNTIME) run --rm $(SELINUX_OPT) -v $(PWD):/workspace:Z ghcr.io/stbenjam/claudelint:main -v --strict

.PHONY: lint-pull
lint-pull: ## Pull the latest claudelint image
	@echo "Pulling latest claudelint image..."
	$(CONTAINER_RUNTIME) pull $(CLAUDELINT_IMAGE)

.PHONY: update
update: ## Update plugin documentation and website data
	@echo "Fixing frontmatter quotes, if any..."
	@python3 scripts/fix_frontmatter_quotes.py
	@echo "Syncing marketplace versions..."
	@python3 scripts/sync_marketplace_versions.py
	@echo "Updating plugin documentation..."
	@python3 scripts/generate_plugin_docs.py
	@echo "Building website data..."
	@python3 scripts/build-website.py

EVAL_REPEAT ?= 1
EVAL_PASS_RATE_THRESHOLD ?= 100

.PHONY: eval-plugins
eval-plugins: ## Run plugin behavioral evals (EVAL_PLUGIN, EVAL_FILTER, EVAL_OUTPUT, EVAL_REPEAT)
	@npm install 2>/dev/null || true
	@exit_code=0; \
	for config in $$(find plugins/$(or $(EVAL_PLUGIN),*) -path '*/evals/*.yaml' 2>/dev/null | sort); do \
		echo "=== Running eval: $$config ==="; \
		CLAUDE_CODE_USE_VERTEX=true \
		PROMPTFOO_PASS_RATE_THRESHOLD=$(EVAL_PASS_RATE_THRESHOLD) \
			npx promptfoo eval \
			-c "$$config" \
			$(if $(EVAL_FILTER),--filter-pattern "$(EVAL_FILTER)") \
			$(if $(EVAL_OUTPUT),--output "$(EVAL_OUTPUT)") \
			--repeat $(EVAL_REPEAT) \
			--no-cache \
		|| exit_code=1; \
	done; \
	exit $$exit_code

.DEFAULT_GOAL := help

