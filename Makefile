# chicago/tui-desktop — initialize, verify, and publish a standalone Kickside module.
MODULE := tui-desktop
TYPE   := plugin
VIS    := public

# The wippy binary every target runs. The compositor's tests need a runtime
# with terminal.ssh and CANCEL, so run them with the local build:
#   make test WIPPY=../runtime/dist/wippy-linux-amd64   # the fork, a sibling of this directory
# With the release binary the desktop suites fail on timeouts ("did not
# register", "no answer"), which looks like a defect in the module.
WIPPY ?= wippy

# pipefail lets the test targets both stream runner output and keep its exit
# code while grepping the log afterwards.
SHELL := bash
.SHELLFLAGS := -o pipefail -ec

.PHONY: init setup check lint test test-pg postgres-up postgres-down verify release-check publish
init:
	node scripts/init-module.mjs --organization "$(ORG)" --module "$(MODULE_NAME)" --title "$(TITLE)" $(if $(NAMESPACE),--namespace "$(NAMESPACE)",) $(if $(TAG),--tag "$(TAG)",) $(if $(GITHUB_OWNER),--github-owner "$(GITHUB_OWNER)",)
setup:
	$(WIPPY) update
	cd test && $(WIPPY) update
check:
	node scripts/check-module.mjs
	node scripts/test-initializer.mjs
lint:
	$(WIPPY) lint
# The runner exits 0 when it discovers zero tests, which turns a broken
# discovery setup into a false-green run. An empty discovery is always a
# defect here — the template ships suites — so both targets fail on it.
# The module declares its own terminal.host — it needs hide_logs — and from
# then on the CLI's terminal host autodetection refuses to choose: it simply
# counts entries of kind terminal.host, and now there are two. The suite runs
# on the application's ordinary host; only the desktop needs its own.
TEST_HOST := wippy.terminal:host
test:
	cd test && $(WIPPY) test --host $(TEST_HOST) 2>&1 | tee .wippy/last-test-run.log && ! grep -q "No tests found" .wippy/last-test-run.log
test-pg:
	cd test && $(WIPPY) test --host $(TEST_HOST) --profile postgres 2>&1 | tee .wippy/last-test-run.log && ! grep -q "No tests found" .wippy/last-test-run.log
postgres-up:
	docker compose -f compose.test.yaml up -d --wait
postgres-down:
	docker compose -f compose.test.yaml down -v
verify: setup check lint test
release-check: verify
	$(WIPPY) auth status
	$(WIPPY) publish --dry-run --create --module-visibility $(VIS) --module-type $(TYPE)
publish:
	node scripts/check-module.mjs
	$(WIPPY) auth status
	$(WIPPY) publish --create --module-visibility $(VIS) --module-type $(TYPE)
