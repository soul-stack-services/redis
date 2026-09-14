SHELL := /bin/sh

.DEFAULT_GOAL := help

.PHONY: help validate test stamp

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "}{printf "%-18s %s\n", $$1, $$2}'

validate: ## Check the manifest and the scenarios (soul-lint)
	@./scripts/validate.sh

test: validate ## validate + the scenarios' L0 runs
	@./scripts/test-l0.sh

stamp: ## Rewrite migrations/schema.lock from the current state_schema
	@./scripts/stamp.sh
