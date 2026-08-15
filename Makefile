.PHONY: check test test-repeat build daemon status models visual-lab settings-lab chat-lab snapshots dev dev-ui open onboarding stop v0 v0-build v0-daemon capture-shim swift-app release release-local sparkle-tools publish publish-dry-run

# `--all-targets` on purpose. Plain `cargo check --workspace` does not compile
# `#[cfg(test)]` modules at all, so a refactor can leave the test code broken
# while `make check` stays green — which is exactly how a8167f8 was committed
# with four compile errors in it.
check:
	cargo check --workspace --all-targets

test:
	cargo test --workspace
	swift test
	swift test --package-path apps/AfterRayCaptureShim

# A concurrency or I/O test does not fail; it fails sometimes. One green run
# proves nothing about a test that races, which is how a capture helper that
# passed one run in five reached main. `make test-repeat N=10` runs the suite
# until it breaks, and `TEST=` narrows it to the one under suspicion.
N ?= 5
TEST ?=
test-repeat:
	@for run in $$(seq 1 $(N)); do \
		printf -- '--- run %s/%s\n' "$$run" "$(N)"; \
		cargo test --workspace $(if $(TEST),-- $(TEST),) || exit $$?; \
	done
	@printf -- '%s consecutive runs passed\n' "$(N)"

build: capture-shim
	cargo build --workspace
	swift build --product afterray-app

capture-shim:
	swift build --package-path apps/AfterRayCaptureShim --product AfterRayCaptureShim

swift-app:
	swift build --product afterray-app

daemon:
	cargo run -p afterrayd

status:
	cargo run -p afterray-cli -- --json status

models:
	./scripts/download-models/download.sh

visual-lab:
	swift run afterray-visual-lab

settings-lab:
	swift run afterray-visual-lab -- --settings --models

chat-lab:
	swift run afterray-visual-lab -- --chat

# Offscreen PNGs of the recall surfaces on mock data. No daemon, no capture,
# no window on screen. Override the destination: make snapshots OUT=/tmp/x
OUT ?= /tmp/afterray-snapshots
snapshots:
	swift run afterray-visual-snapshots $(OUT)

dev:
	./scripts/dev.sh

dev-ui:
	./scripts/dev.sh --ui

open:
	./scripts/open-dev.sh

# Rebuild the real app and force the welcome flow without deleting the user's
# completion preference.
onboarding: v0-build
	./scripts/open-dev.sh --onboarding

stop:
	./scripts/stop-dev.sh

v0:
	./scripts/run-v0.sh

v0-build:
	./scripts/run-v0.sh --build-only

v0-daemon:
	./scripts/run-v0.sh --daemon-only

release:
	./scripts/build-release.sh

release-local:
	./scripts/build-release.sh --local --allow-dirty

# Sparkle's sign_update/generate_keys/generate_appcast are not part of the
# Swift package; fetch them once per machine before the first release.
sparkle-tools:
	./scripts/fetch-sparkle-tools.sh

publish:
	./scripts/publish-release.sh

publish-dry-run:
	./scripts/publish-release.sh --dry-run
