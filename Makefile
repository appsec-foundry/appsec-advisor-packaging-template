APPSEC_ADVISOR_URL ?= https://github.com/appsec-foundry/appsec-advisor.git
# Pin the single packaging branch to the current upstream release. Treat an
# explicitly exported empty CI variable as unset so it cannot fall back to latest.
APPSEC_ADVISOR_REF ?=
ifeq ($(strip $(APPSEC_ADVISOR_REF)),)
APPSEC_ADVISOR_REF := v0.6.0-beta.1
endif
APPSEC_ADVISOR_DEST ?= upstream/appsec-advisor
APPSEC_ADVISOR_SOURCE ?= $(APPSEC_ADVISOR_DEST)
INTERNAL_NAME ?= acme-appsec
# Version is derived by scripts/package-local.sh as <upstream>+<org-id>.<org-rev>
# (e.g. 0.6.0-beta.1+acme.1). Bump ORG_REV for org-only changes (org-profile/,
# org-skills/, package-policy.yaml); it resets to 1 whenever
# APPSEC_ADVISOR_REF moves. Set VERSION to override the whole string.
ORG_REV ?= 1
VERSION ?=
LOCAL_MARKETPLACE_NAME ?= $(INTERNAL_NAME)-local
LOCAL_MARKETPLACE_SCOPE ?= local

ifeq ($(APPSEC_ADVISOR_SOURCE),$(APPSEC_ADVISOR_DEST))
FETCH_TARGET := fetch-upstream
else
FETCH_TARGET :=
endif

.DEFAULT_GOAL := help

.PHONY: help lint check release-check fetch-upstream upstream-check validate package package-archive local-marketplace install-local smoke ci-github ci-gitlab clean distclean rebuild test

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

test: ## Run the shell-script test suite + coverage gate (skipped if tests/ is absent)
	@if [ -f tests/run.sh ]; then \
		bash tests/run.sh; \
	else \
		echo "no tests/ in this repo — skipping"; \
	fi

lint: ## shellcheck the shell scripts (skipped if shellcheck is absent)
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh $$([ -f tests/run.sh ] && echo tests/run.sh); \
	else \
		echo "shellcheck not installed — skipping (see https://github.com/koalaman/shellcheck#installing)"; \
	fi

check: lint test ## Offline gate: lint + test (no network, no upstream fetch)

release-check: ## Release-boundary gate: check + validate + build a clean plugin against upstream
	@$(MAKE) --no-print-directory check
	@$(MAKE) --no-print-directory upstream-check || echo "  ^ upstream drift (advisory) — not blocking release-check"
	@$(MAKE) --no-print-directory validate
	@$(MAKE) --no-print-directory package

upstream-check: ## Read-only drift check vs upstream (exit 1 if a newer release exists)
	APPSEC_ADVISOR_URL="$(APPSEC_ADVISOR_URL)" APPSEC_ADVISOR_REF="$(APPSEC_ADVISOR_REF)" APPSEC_ADVISOR_DEST="$(APPSEC_ADVISOR_DEST)" scripts/upstream-check.sh

fetch-upstream: ## Clone/checkout upstream appsec-advisor at APPSEC_ADVISOR_REF
	APPSEC_ADVISOR_URL="$(APPSEC_ADVISOR_URL)" APPSEC_ADVISOR_REF="$(APPSEC_ADVISOR_REF)" APPSEC_ADVISOR_DEST="$(APPSEC_ADVISOR_DEST)" scripts/fetch-upstream.sh

validate: $(FETCH_TARGET) ## Validate org-profile.yaml against the upstream schema
	python3 "$(APPSEC_ADVISOR_SOURCE)/scripts/validate_org_profile.py" org-profile/org-profile.yaml

package: $(FETCH_TARGET) ## Fetch + build + smoke-test the plugin into build/<name>/
	APPSEC_ADVISOR_URL="$(APPSEC_ADVISOR_URL)" APPSEC_ADVISOR_REF="$(APPSEC_ADVISOR_REF)" APPSEC_ADVISOR_DEST="$(APPSEC_ADVISOR_DEST)" APPSEC_ADVISOR_SOURCE="$(APPSEC_ADVISOR_SOURCE)" INTERNAL_NAME="$(INTERNAL_NAME)" ORG_REV="$(ORG_REV)" VERSION="$(VERSION)" scripts/package-local.sh

package-archive: $(FETCH_TARGET) ## Like package, plus a dist/*.tgz + .sha256 archive
	APPSEC_ADVISOR_URL="$(APPSEC_ADVISOR_URL)" APPSEC_ADVISOR_REF="$(APPSEC_ADVISOR_REF)" APPSEC_ADVISOR_DEST="$(APPSEC_ADVISOR_DEST)" APPSEC_ADVISOR_SOURCE="$(APPSEC_ADVISOR_SOURCE)" INTERNAL_NAME="$(INTERNAL_NAME)" ORG_REV="$(ORG_REV)" VERSION="$(VERSION)" ARCHIVE=1 scripts/package-local.sh

local-marketplace: package ## Prepare build/ as a local Claude Code marketplace
	python3 scripts/prepare-local-marketplace.py --build-root build --plugin-name "$(INTERNAL_NAME)" --marketplace-name "$(LOCAL_MARKETPLACE_NAME)"

install-local: local-marketplace ## Register the local marketplace and install the built plugin
	@command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI not found" >&2; exit 2; }
	claude plugin marketplace add "$(abspath build)" --scope "$(LOCAL_MARKETPLACE_SCOPE)"
	claude plugin install "$(INTERNAL_NAME)@$(LOCAL_MARKETPLACE_NAME)" --scope "$(LOCAL_MARKETPLACE_SCOPE)"

smoke: $(FETCH_TARGET) ## Smoke-test an already-built package
	python3 "$(APPSEC_ADVISOR_SOURCE)/scripts/smoke_test_package.py" "build/$(INTERNAL_NAME)" --name "$(INTERNAL_NAME)"

clean: ## Remove generated dirs (upstream/ build/ dist/)
	rm -rf upstream/ build/ dist/

distclean: clean ## clean, then strip template build glue from a scaffolded repo
	rm -rf ci-templates/ scripts/ AGENTS.md README.md Makefile

rebuild: clean package ## clean then package

ci-github: ## Install the GitHub Actions packaging workflow
	mkdir -p .github/workflows
	cp ci-templates/github/workflows/package.yml .github/workflows/package.yml

ci-gitlab: ## Install the GitLab CI config
	cp ci-templates/gitlab-ci.yml .gitlab-ci.yml
