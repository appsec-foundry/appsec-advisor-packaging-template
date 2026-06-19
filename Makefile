APPSEC_ADVISOR_URL ?= https://github.com/matthiasrohr/appsec-advisor.git
APPSEC_ADVISOR_REF ?= latest
APPSEC_ADVISOR_DEST ?= upstream/appsec-advisor
APPSEC_ADVISOR_SOURCE ?= $(APPSEC_ADVISOR_DEST)
INTERNAL_NAME ?= acme-appsec
VERSION ?= 0.4.0-local

ifeq ($(APPSEC_ADVISOR_SOURCE),$(APPSEC_ADVISOR_DEST))
FETCH_TARGET := fetch-upstream
else
FETCH_TARGET :=
endif

.PHONY: fetch-upstream validate package package-archive smoke ci-github ci-gitlab clean distclean rebuild test

test:
	bash tests/run.sh

fetch-upstream:
	APPSEC_ADVISOR_URL="$(APPSEC_ADVISOR_URL)" APPSEC_ADVISOR_REF="$(APPSEC_ADVISOR_REF)" APPSEC_ADVISOR_DEST="$(APPSEC_ADVISOR_DEST)" scripts/fetch-upstream.sh

validate: $(FETCH_TARGET)
	python3 "$(APPSEC_ADVISOR_SOURCE)/scripts/validate_org_profile.py" org-profile/org-profile.yaml

package: $(FETCH_TARGET)
	APPSEC_ADVISOR_URL="$(APPSEC_ADVISOR_URL)" APPSEC_ADVISOR_REF="$(APPSEC_ADVISOR_REF)" APPSEC_ADVISOR_DEST="$(APPSEC_ADVISOR_DEST)" APPSEC_ADVISOR_SOURCE="$(APPSEC_ADVISOR_SOURCE)" INTERNAL_NAME="$(INTERNAL_NAME)" VERSION="$(VERSION)" scripts/package-local.sh

package-archive: $(FETCH_TARGET)
	APPSEC_ADVISOR_URL="$(APPSEC_ADVISOR_URL)" APPSEC_ADVISOR_REF="$(APPSEC_ADVISOR_REF)" APPSEC_ADVISOR_DEST="$(APPSEC_ADVISOR_DEST)" APPSEC_ADVISOR_SOURCE="$(APPSEC_ADVISOR_SOURCE)" INTERNAL_NAME="$(INTERNAL_NAME)" VERSION="$(VERSION)" ARCHIVE=1 scripts/package-local.sh

smoke: $(FETCH_TARGET)
	python3 "$(APPSEC_ADVISOR_SOURCE)/scripts/smoke_test_package.py" "build/$(INTERNAL_NAME)" --name "$(INTERNAL_NAME)"

clean:
	rm -rf upstream/ build/ dist/

distclean: clean
	rm -rf ci-templates/ scripts/ AGENTS.md README.md Makefile

rebuild: clean package

ci-github:
	mkdir -p .github/workflows
	cp ci-templates/github/workflows/package.yml .github/workflows/package.yml

ci-gitlab:
	cp ci-templates/gitlab-ci.yml .gitlab-ci.yml
