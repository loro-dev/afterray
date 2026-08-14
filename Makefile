.PHONY: check test build daemon status models visual-lab settings-lab snapshots dev dev-ui open stop v0 v0-build v0-daemon capture-shim swift-app

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
