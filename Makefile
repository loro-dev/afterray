.PHONY: check check-i18n test docs-sync verify test-repeat build daemon status models visual-lab visual-lab-summary-stress visual-lab-stress visual-lab-stress-profile visual-lab-window-stress visual-lab-window-stress-profile settings-lab chat-lab compute-lab snapshots dev dev-ui open onboarding stop v0 v0-build v0-daemon capture-shim swift-app release release-local sparkle-tools release-preflight verify-release publish publish-dry-run tag-release

# `--all-targets` on purpose. Plain `cargo check --workspace` does not compile
# `#[cfg(test)]` modules at all, so a refactor can leave the test code broken
# while `make check` stays green — which is exactly how a8167f8 was committed
# with four compile errors in it.
check:
	cargo check --workspace --all-targets
	./scripts/check-i18n.sh

check-i18n:
	./scripts/check-i18n.sh

test: docs-sync
	cargo test --workspace
	swift test
	swift test --package-path apps/AfterRayCaptureShim
	./scripts/check-i18n.sh

# The one command a change has to pass before it is pushed: docs gate, lint,
# then the suites. Ordered cheapest-first, so a broken link fails in a second
# instead of after a Swift build. `make test` is the subset without the lint
# gate; this is what the PR checklist in AGENTS.md means.
verify: docs-sync
	cargo clippy --workspace --all-targets -- -D warnings
	cargo test --workspace
	swift test
	swift test --package-path apps/AfterRayCaptureShim
	./scripts/check-i18n.sh

# Links, decision-record shape, and the hash of the code under every `@dec:`
# marker. Node runs the TypeScript directly — no dependencies, no node_modules.
# A red anchor hash means the decision was not re-read when its code changed;
# re-read it, then `node scripts/docs-gate/main.ts --write`.
docs-sync:
	node scripts/docs-gate/main.ts

# A concurrency or I/O test does not fail; it fails sometimes. One green run
# proves nothing about a test that races, which is how a capture helper that
# passed one run in five reached main. `make test-repeat N=10` runs the suite
# until it breaks, and `TEST=` narrows it to the one under suspicion. XCTest
# filters use `Suite/test` and route to SwiftPM; Rust's filters have no slash.
N ?= 5
TEST ?=
test-repeat:
	@for run in $$(seq 1 $(N)); do \
		printf -- '--- run %s/%s\n' "$$run" "$(N)"; \
		$(if $(findstring /,$(TEST)),swift test --filter '$(TEST)',cargo test --workspace $(if $(TEST),-- $(TEST),)) || exit $$?; \
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

visual-lab-summary-stress:
	swift run afterray-visual-lab -- --summary-stress

visual-lab-stress:
	swift run afterray-visual-lab -- --stress

visual-lab-stress-profile:
	AFTERRAY_UI_PERF_LOG=1 AFTERRAY_UI_PERF_AUTORUN=1 swift run -c release afterray-visual-lab -- --stress

visual-lab-window-stress:
	swift run afterray-visual-lab -- --window-stress

visual-lab-window-stress-profile:
	AFTERRAY_UI_PERF_LOG=1 AFTERRAY_UI_PERF_AUTORUN=1 AFTERRAY_UI_PERF_AUTORUN_REVERSE=1 AFTERRAY_UI_PERF_AUTORUN_DELAY_MS=1500 swift run -c release afterray-visual-lab -- --window-stress

# Record an Instruments trace of a timeline scrub. The scrub is synthesised
# through the production input path (AFTERRAY_UI_PERF_AUTORUN), so two runs are
# comparable; AFTERRAY_UI_PERF_LOG prints frame intervals next to the trace.
#
# Release build on purpose — a debug build's numbers are noise.
#
#   make profile-scrub                                # CPU hotspots
#   make profile-scrub TEMPLATE='SwiftUI'             # which bodies re-evaluate
#   make profile-scrub TEMPLATE='Animation Hitches'   # dropped frames, and why
#   make profile-scrub TEMPLATE='Metal System Trace'  # GPU
#   make profile-scrub LAB_ARGS='--stress'            # without the summary panel
TEMPLATE ?= Time Profiler
TRACE ?= /tmp/afterray-scrub.trace
LAB_ARGS ?= --stress --summary-stress
PROFILE_DELAY_MS ?= 3000

profile-scrub:
	swift build -c release --product afterray-visual-lab
	rm -rf "$(TRACE)"
	xcrun xctrace record \
		--template "$(TEMPLATE)" \
		--output "$(TRACE)" \
		--time-limit 20s \
		--no-prompt \
		--env AFTERRAY_UI_PERF_LOG=1 \
		--env AFTERRAY_UI_PERF_AUTORUN=1 \
		--env AFTERRAY_UI_PERF_AUTORUN_DELAY_MS=$(PROFILE_DELAY_MS) \
		--launch -- "$$(swift build -c release --show-bin-path)/afterray-visual-lab" $(LAB_ARGS)
	@echo "trace: $(TRACE)"
	open "$(TRACE)"

# Same, but against the real app on the real vault — which is the one that
# matters, because the lab's fixtures are not your data. Start the app
# (`make dev`), run this, then scrub the timeline for the recording window.
#
# No entitlements needed: the dev bundle is ad-hoc signed without the hardened
# runtime, so Instruments can attach. A release build is hardened and cannot be
# attached to without re-signing it with `get-task-allow`.
PROFILE_SECONDS ?= 20s
# Labelled and timestamped, because comparing two runs is the whole point and a
# fixed filename silently overwrites the run you wanted to compare against.
#   make profile-app RUN=panel-open
#   make profile-app RUN=panel-closed
RUN ?= run
APP_TRACE ?= /tmp/afterray-$(RUN)-$(shell date +%H%M%S).trace

profile-app:
	@pid="$$(pgrep -f 'AfterRay.app/Contents/MacOS/AfterRay' | head -1)"; \
	if [ -z "$$pid" ]; then echo "AfterRay is not running — start it with 'make dev'"; exit 1; fi; \
	echo "==> recording pid $$pid for $(PROFILE_SECONDS) — scrub the timeline now"; \
	xcrun xctrace record --template "$(TEMPLATE)" --output "$(APP_TRACE)" \
		--time-limit $(PROFILE_SECONDS) --no-prompt --attach "$$pid"
	@echo "==> $(APP_TRACE)"
	@echo "    make profile-report TRACE_IN=$(APP_TRACE)"

# Summarise a recorded trace in the terminal. The call tree is the first thing
# you want and clicking down to it in the GUI is slow.
#   make profile-report TRACE_IN=/tmp/afterray-app.trace
TRACE_IN ?= /tmp/afterray-app.trace
profile-report:
	xcrun xctrace export --input "$(TRACE_IN)" \
		--xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
		--output /tmp/afterray-timeprofile.xml
	python3 scripts/analyze-trace.py /tmp/afterray-timeprofile.xml $(if $(FROM),--from=$(FROM)) $(if $(TO),--to=$(TO))

# The A/B that actually controls for anything: one recording, the change made
# halfway through, compared window against window. Two separate hand-scrubbed
# recordings are not comparable — how hard you scrubbed dominates.
#   make profile-app RUN=ab PROFILE_SECONDS=24s
#   make profile-ab TRACE_IN=/tmp/afterray-ab-HHMMSS.trace
# Ground truth for frame pacing: the app's own display-link measurement,
# not inferred from CPU samples. Prints one line per settled scrub.
#
# A user default, not an environment variable, because the app has to be
# launched by launchd to own its TCC identity — start the binary from a
# terminal and macOS attributes Screen Recording to the terminal, so you land
# on the permissions wall. `open --env` reaches the app but its stdout goes
# nowhere, hence the unified log.
perf-log-on:
	defaults write dev.afterray.app AfterRayUIPerfLog -bool YES
	@echo "on. restart the app (make stop && make dev), scrub, then: make perf-log"

perf-log-off:
	defaults delete dev.afterray.app AfterRayUIPerfLog 2>/dev/null || true

perf-log:
	log stream --predicate 'subsystem == "dev.afterray" AND category == "ui-perf"' --style compact

# Frame rate, which is the number that matters. CPU% saturates and cannot tell
# two configurations apart.
profile-frames:
	xcrun xctrace export --input "$(TRACE_IN)" \
		--xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
		--output /tmp/afterray-timeprofile.xml
	python3 scripts/analyze-frames.py /tmp/afterray-timeprofile.xml

# Two traces side by side. Keep the zoom level and the scrub speed the same
# between them or the comparison means nothing — run count scales with zoom,
# and how hard you scrubbed dominates everything else.
#   make profile-vs BEFORE=/tmp/a.trace AFTER=/tmp/b.trace
profile-vs:
	@for t in "$(BEFORE)" "$(AFTER)"; do \
		echo ""; echo "########## $$t"; \
		xcrun xctrace export --input "$$t" \
			--xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
			--output /tmp/afterray-vs.xml >/dev/null 2>&1; \
		python3 scripts/analyze-frames.py /tmp/afterray-vs.xml; \
	done

profile-ab:
	xcrun xctrace export --input "$(TRACE_IN)" \
		--xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
		--output /tmp/afterray-timeprofile.xml
	@echo "=== first half ==="
	@python3 scripts/analyze-trace.py /tmp/afterray-timeprofile.xml --from=0 --to=10 | head -1
	@echo "=== second half ==="
	@python3 scripts/analyze-trace.py /tmp/afterray-timeprofile.xml --from=14 --to=24 | head -1

settings-lab:
	swift run afterray-visual-lab -- --settings --models

chat-lab:
	swift run afterray-visual-lab -- --chat

# The local-computation dashboard on fixtures. Opens on the awkward state
# (on battery, summaries held) because that is what it has to read well in.
compute-lab:
	swift run afterray-visual-lab -- --compute

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

release: release-preflight
	./scripts/build-release.sh

release-local:
	./scripts/build-release.sh --local --allow-dirty

# Sparkle's sign_update/generate_keys/generate_appcast are not part of the
# Swift package; fetch them once per machine before the first release.
sparkle-tools:
	./scripts/fetch-sparkle-tools.sh

release-preflight:
	./scripts/release-preflight.sh

verify-release:
	@test -n "$(MANIFEST)" || (echo 'usage: make verify-release MANIFEST=dist/AfterRay-<version>-arm64.json' >&2; exit 64)
	./scripts/verify-release.sh "$(MANIFEST)"

publish:
	@test -n "$(MANIFEST)" || (echo 'usage: make publish MANIFEST=dist/AfterRay-<version>-arm64.json' >&2; exit 64)
	./scripts/publish-release.sh "$(MANIFEST)"

publish-dry-run:
	@test -n "$(MANIFEST)" || (echo 'usage: make publish-dry-run MANIFEST=dist/AfterRay-<version>-arm64.json' >&2; exit 64)
	./scripts/publish-release.sh --dry-run "$(MANIFEST)"

tag-release:
	@test -n "$(MANIFEST)" || (echo 'usage: make tag-release MANIFEST=dist/AfterRay-<version>-arm64.json' >&2; exit 64)
	./scripts/tag-release.sh "$(MANIFEST)"
