HELM ?= helm
CHART_DIR := charts/arcadedb
HELM_UNITTEST_VERSION := 0.5.2

.PHONY: help lint test-unit test-config-seed test-config-keys test-integration test plugin-install

help:
	@echo "Targets:"
	@echo "  make lint              Run helm lint"
	@echo "  make test-unit         Run helm-unittest suites"
	@echo "  make test-config-seed  Run the config-seed init container script against sample files"
	@echo "  make test-config-keys  Check rendered -Darcadedb.* keys against the server image (needs docker)"
	@echo "  make test-integration  Run kind-based integration tests"
	@echo "  make test              All of the above"
	@echo "  make plugin-install    (Re)install helm-unittest plugin at pinned version"

lint:
	$(HELM) lint $(CHART_DIR)

# Idempotent: install or reinstall helm-unittest only if missing or version-mismatched.
plugin-install:
	@current=$$($(HELM) plugin list 2>/dev/null | awk '$$1=="unittest"{print $$2}'); \
	if [ "$$current" != "$(HELM_UNITTEST_VERSION)" ]; then \
	  $(HELM) plugin uninstall unittest 2>/dev/null || true; \
	  $(HELM) plugin install https://github.com/helm-unittest/helm-unittest --version $(HELM_UNITTEST_VERSION) --verify=false; \
	fi

test-unit: plugin-install
	$(HELM) unittest $(CHART_DIR)
	HELM=$(HELM) bash ci/check-failed-template.sh

test-config-seed:
	bash ci/test-config-seed.sh

test-config-keys:
	bash ci/check-config-keys.sh

test-integration:
	bash ci/integration-test.sh

test: lint test-unit test-config-seed test-config-keys test-integration
