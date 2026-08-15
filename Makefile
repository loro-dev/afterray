.PHONY: check test build daemon status models visual-lab settings-lab chat-lab snapshots dev dev-ui open stop v0 v0-build v0-daemon capture-shim swift-app release release-local sparkle-tools publish publish-dry-run

check:
	cargo check --workspace

test:
	cargo test --workspace
	swift test

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
