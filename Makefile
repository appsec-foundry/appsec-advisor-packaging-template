APPSEC_ADVISOR_URL ?= https://github.com/appsec-foundry/appsec-advisor.git
# The initializer replaces this template default with either the resolved stable
# release tag or the moving dev branch. Treat an explicitly exported empty CI
# variable as unset so generated repositories still use their persisted choice.
APPSEC_ADVISOR_REF ?=
ifeq ($(strip $(APPSEC_ADVISOR_REF)),)
APPSEC_ADVISOR_REF := v0.6.0-beta.1
endif
APPSEC_ADVISOR_DEST ?= upstream/appsec-advisor
APPSEC_ADVISOR_SOURCE ?= $(APPSEC_ADVISOR_DEST)
INTERNAL_NAME ?= acme-appsec
# Internal packaging repository shown in packaged help and README output. Keep
# empty until the internal HTTPS URL exists.
INTERNAL_REPOSITORY_URL ?=
# Organization-owned version shown in the plugin banner, help, manifest and
# archive name. Bump it when publishing a new internal package release.
PACKAGE_VERSION ?= 0.1.0
# Backward-compatible one-off override; normally leave this empty and edit
# PACKAGE_VERSION instead.
VERSION ?=
RELEASE_VERSION ?=
export PACKAGE_VERSION VERSION INTERNAL_REPOSITORY_URL
LOCAL_MARKETPLACE_NAME ?= $(INTERNAL_NAME)-local
LOCAL_MARKETPLACE_SCOPE ?= local
APPSEC_ADVISOR_TEMPLATE_URL ?= https://github.com/appsec-foundry/appsec-advisor-packaging-template.git
# The initializer replaces this moving bootstrap ref with the exact template
# commit used to create or reinitialize a generated repository.
APPSEC_ADVISOR_TEMPLATE_REF ?= main
APPSEC_ADVISOR_TEMPLATE_SOURCE ?=
REINIT_BUILD ?= 1
export APPSEC_ADVISOR_TEMPLATE_URL APPSEC_ADVISOR_TEMPLATE_REF APPSEC_ADVISOR_TEMPLATE_SOURCE REINIT_BUILD

# Environment passed to the fetch and packaging scripts. The recipes are
# silenced with '@' so the scripts' own '==>' progress lines start the output
# instead of a 200-character variable assignment.
UPSTREAM_ENV := APPSEC_ADVISOR_URL="$(APPSEC_ADVISOR_URL)" APPSEC_ADVISOR_REF="$(APPSEC_ADVISOR_REF)" APPSEC_ADVISOR_DEST="$(APPSEC_ADVISOR_DEST)"
PACKAGE_ENV := $(UPSTREAM_ENV) APPSEC_ADVISOR_SOURCE="$(APPSEC_ADVISOR_SOURCE)" INTERNAL_NAME="$(INTERNAL_NAME)"

# Printed by the read-only check targets when they exit 1, so the Make error
# that follows reads as the drift signal it is.
DRIFT_NOTE := NOTE: the finding above is the result — these checks report drift by failing, so the 'Error 1' below is that signal and not a broken build.

ifeq ($(APPSEC_ADVISOR_SOURCE),$(APPSEC_ADVISOR_DEST))
FETCH_TARGET := fetch-upstream
else
FETCH_TARGET :=
endif

.DEFAULT_GOAL := help

.PHONY: help lint check release release-check fetch-upstream upstream-check packaging-template-check baseline-check check-updates drift-check upstream-update validate package release-package package-archive local-marketplace install-local smoke ci-github ci-gitlab clean rebuild reinit test

help: ## Show this help
	@if [ -t 1 ] && [ -z "$${NO_COLOR:-}" ]; then \
		hdr=$$(printf '\033[1m'); tgt=$$(printf '\033[36m'); off=$$(printf '\033[0m'); \
	fi; \
	awk -v hdr="$$hdr" -v tgt="$$tgt" -v off="$$off" 'BEGIN {FS = ":.*## "} \
		/^##@ / {printf "\n%s%s%s\n", hdr, substr($$0, 5), off; next} \
		/^[a-zA-Z0-9_-]+:.*## / {printf "  %s%-26s%s %s\n", tgt, $$1, off, $$2}' $(MAKEFILE_LIST)
	@printf '\nCurrent settings (override on the command line or via env):\n'
	@printf '  INTERNAL_NAME=%s\n  PACKAGE_VERSION=%s\n  APPSEC_ADVISOR_REF=%s\n  APPSEC_ADVISOR_TEMPLATE_REF=%s\n' \
		'$(INTERNAL_NAME)' '$(PACKAGE_VERSION)' '$(APPSEC_ADVISOR_REF)' '$(APPSEC_ADVISOR_TEMPLATE_REF)'

##@ Build

package: $(FETCH_TARGET) ## Fetch + build + smoke-test the plugin into build/<name>/
	@$(PACKAGE_ENV) scripts/package-local.sh

rebuild: clean package ## clean then package

validate: $(FETCH_TARGET) ## Validate org-profile.yaml against the upstream schema
	@echo "==> Validating org-profile.yaml against $(APPSEC_ADVISOR_REF)"
	@python3 "$(APPSEC_ADVISOR_SOURCE)/scripts/validate_org_profile.py" org-profile/org-profile.yaml
	@PYTHONDONTWRITEBYTECODE=1 python3 scripts/check-org-hook-collisions.py --source "$(APPSEC_ADVISOR_SOURCE)" --profile org-profile/org-profile.yaml

fetch-upstream: ## Clone/checkout upstream appsec-advisor at APPSEC_ADVISOR_REF
	@$(UPSTREAM_ENV) scripts/fetch-upstream.sh

smoke: $(FETCH_TARGET) ## Smoke-test an already-built package
	@echo "==> Smoke-testing build/$(INTERNAL_NAME)"
	@python3 "$(APPSEC_ADVISOR_SOURCE)/scripts/smoke_test_package.py" "build/$(INTERNAL_NAME)" --name "$(INTERNAL_NAME)"

##@ Try it out locally

local-marketplace: package ## Prepare build/ as a local Claude Code marketplace
	python3 scripts/prepare-local-marketplace.py --build-root build --plugin-name "$(INTERNAL_NAME)" --marketplace-name "$(LOCAL_MARKETPLACE_NAME)"

install-local: local-marketplace ## Register the local marketplace and install the built plugin
	@command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI not found" >&2; exit 2; }
	claude plugin marketplace add "$(abspath build)" --scope "$(LOCAL_MARKETPLACE_SCOPE)"
	claude plugin install "$(INTERNAL_NAME)@$(LOCAL_MARKETPLACE_NAME)" --scope "$(LOCAL_MARKETPLACE_SCOPE)"

##@ Check

check: lint test ## Offline gate: lint + test (no network, no upstream fetch)
	@echo "OK: offline checks passed"

lint: ## shellcheck the shell scripts (skipped if shellcheck is absent)
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "==> shellcheck scripts/"; \
		shellcheck scripts/*.sh $$([ -f tests/run.sh ] && echo tests/run.sh); \
	else \
		echo "NOTE: shellcheck not installed — skipping (see https://github.com/koalaman/shellcheck#installing)"; \
	fi

test: ## Run the shell-script test suite + coverage gate (skipped if tests/ is absent)
	@if [ -f tests/run.sh ]; then \
		bash tests/run.sh; \
	else \
		echo "NOTE: no tests/ in this repo — skipping"; \
	fi

##@ Upstream and template

upstream-check: ## Read-only drift check for the appsec-advisor ref and releases
	@status=0; \
	$(UPSTREAM_ENV) scripts/upstream-check.sh || status=$$?; \
	if [ "$$status" -eq 1 ]; then \
		echo "$(DRIFT_NOTE)"; \
	fi; \
	exit $$status

# 'upstream-check' reports commit drift and release drift through the same exit
# status, but only commit drift is something a rebuild fixes: a newer release
# tag is built only after APPSEC_ADVISOR_REF is raised by hand. So decide on the
# kind of drift reported, not on the exit status alone.
upstream-update: ## Rebuild only when the selected upstream ref moved to a new commit
	@status=0; \
	out="$$($(UPSTREAM_ENV) scripts/upstream-check.sh 2>&1)" || status=$$?; \
	printf '%s\n' "$$out"; \
	if [ "$$status" -ge 2 ]; then \
		echo "ERROR: upstream check could not complete — nothing rebuilt" >&2; exit 2; \
	fi; \
	if printf '%s\n' "$$out" | grep -q '^DRIFT (release)'; then \
		echo "NOTE: a newer release exists — raise APPSEC_ADVISOR_REF in the Makefile to build it"; \
	fi; \
	if printf '%s\n' "$$out" | grep -qE '^(DRIFT \(commit\)|NOTE: no local checkout)'; then \
		echo "==> rebuilding from $(APPSEC_ADVISOR_REF)"; \
		$(MAKE) --no-print-directory rebuild; \
	else \
		echo "OK: nothing to rebuild"; \
	fi

# Depends on the upstream checkout: the baseline check runs its URL through the
# core's SSRF guard, so a scheduled run has to have the core on disk. With
# APPSEC_ADVISOR_SOURCE pointing elsewhere, FETCH_TARGET is empty and nothing is
# fetched.
check-updates: $(FETCH_TARGET) ## Check appsec-advisor and secure-coding baseline for updates
	@status=0; \
	$(UPSTREAM_ENV) scripts/upstream-check.sh || status=$$?; \
	echo; \
	baseline_status=0; \
	python3 scripts/baseline-upstream-check.py --profile org-profile/org-profile.yaml --core-config "$(APPSEC_ADVISOR_SOURCE)/config.json" || baseline_status=$$?; \
	if [ "$$status" -eq 2 ] || [ "$$baseline_status" -eq 2 ]; then \
		echo "ERROR: at least one upstream check could not complete" >&2; exit 2; \
	fi; \
	if [ "$$status" -eq 1 ] || [ "$$baseline_status" -eq 1 ]; then \
		echo "DRIFT: at least one upstream source has changed"; \
		echo "$(DRIFT_NOTE)"; exit 1; \
	fi; \
	echo "OK: appsec-advisor and baseline are current"

baseline-check: ## Read-only drift check for the configured secure-coding baseline
	@status=0; \
	python3 scripts/baseline-upstream-check.py --profile org-profile/org-profile.yaml --core-config "$(APPSEC_ADVISOR_SOURCE)/config.json" || status=$$?; \
	if [ "$$status" -eq 1 ]; then \
		echo "$(DRIFT_NOTE)"; \
	fi; \
	exit $$status

packaging-template-check: ## Read-only check for a newer packaging-template revision
	@status=0; \
	APPSEC_ADVISOR_TEMPLATE_URL="$(APPSEC_ADVISOR_TEMPLATE_URL)" APPSEC_ADVISOR_TEMPLATE_REF="$(APPSEC_ADVISOR_TEMPLATE_REF)" scripts/packaging-template-check.sh || status=$$?; \
	if [ "$$status" -eq 1 ]; then \
		echo "$(DRIFT_NOTE)"; \
	fi; \
	exit $$status

# Deprecated alias for check-updates; kept working, left out of `make help`.
drift-check:
	@$(MAKE) --no-print-directory check-updates

##@ Release

release-check: ## Release-boundary gate: check + validate + build a clean plugin against upstream
	@echo "==> [1/5] check (lint + test)"
	@$(MAKE) --no-print-directory check
	# Not in `make check`: the documented workflow commits the initializer first
	# and repins the README after, so the two disagree in between. A release must
	# not carry that state. Guarded because a scaffolded repository has no such
	# pin and does not ship the script.
	@if [ -f scripts/check-quickstart-pin.py ]; then \
		echo "==> [2/5] quick-start pin"; \
		python3 scripts/check-quickstart-pin.py; \
	else \
		echo "==> [2/5] quick-start pin (not applicable)"; \
	fi
	@echo "==> [3/5] check-updates (advisory)"
	@$(MAKE) --no-print-directory check-updates || echo "NOTE: update available or check error (advisory) — not blocking release-check"
	@echo "==> [4/5] validate"
	@$(MAKE) --no-print-directory validate
	@echo "==> [5/5] package"
	@$(MAKE) --no-print-directory package
	@echo "OK: release-check passed"

release-package: $(FETCH_TARGET) ## Build distributable .tgz/.zip archives with checksums
	@echo "==> Building distributable archives for $(INTERNAL_NAME)"
	@$(PACKAGE_ENV) ARCHIVE=1 scripts/package-local.sh

# Deprecated alias for release-package; kept working, left out of `make help`.
package-archive: release-package

release: ## Validate, tag and push a release (RELEASE_VERSION=x.y.z)
	@scripts/release.sh "$(RELEASE_VERSION)"

##@ Maintenance

clean: ## Remove generated dirs, coverage output and local tool caches
	rm -rf upstream/ build/ dist/ .ruff_cache/ scripts/__pycache__/ tests/__pycache__/ org-profile/hooks/__pycache__/ coverage.lcov

reinit: ## Reapply the selected template ref using the existing settings
	scripts/reinit-org-repo.sh

ci-github: ## Install the GitHub Actions packaging workflow
	mkdir -p .github/workflows
	cp ci-templates/github/workflows/package.yml .github/workflows/package.yml

ci-gitlab: ## Install the GitLab CI config
	cp ci-templates/gitlab-ci.yml .gitlab-ci.yml
