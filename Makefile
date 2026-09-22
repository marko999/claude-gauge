SHELL := /bin/bash
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
DIST := $(ROOT)/dist
APP := $(DIST)/ClaudeGauge.app
BIN_NAME := ClaudeGauge
VERSION := 0.2.0
RELEASE_ZIP := $(DIST)/ClaudeGauge-v$(VERSION)-macOS-arm64.zip
RELEASE_SHA := $(RELEASE_ZIP).sha256

.PHONY: all build test app run clean smoke-check release-zip

all: test app

build:
	cd "$(ROOT)" && swift build -c release

test:
	cd "$(ROOT)" && swift run --package-path "$(ROOT)" ClaudeGaugeCoreTests

app: build
	bash "$(ROOT)/scripts/build-app.sh"

# Rebuild, restart the running instance, and open the fresh bundle.
run: app
	-pkill -x $(BIN_NAME)
	open "$(APP)"

clean:
	cd "$(ROOT)" && swift package clean
	rm -rf "$(DIST)/ClaudeGauge.app" "$(ROOT)/.build"
	rm -f "$(RELEASE_ZIP)" "$(RELEASE_SHA)"

# Read-only bundle inspection (no secrets printed).
smoke-check:
	@test -d "$(APP)" || (echo "Missing $(APP); run make app first" && exit 1)
	@echo "Bundle: $(APP)"
	@plutil -p "$(APP)/Contents/Info.plist" | head -40
	@echo "--- executable ---"
	@file "$(APP)/Contents/MacOS/$(BIN_NAME)"
	@echo "--- codesign ---"
	@codesign -dv "$(APP)" 2>&1 | head -20
	@echo "--- accidental credential scan (paths/names only) ---"
	@! find "$(APP)" \( -name '*.db' -o -name '*token*' -o -name '*credential*' -o -name '.env*' -o -name '*.pem' -o -name '*.key' \) -print | grep . \
		|| (echo "FAIL: suspicious files in bundle" && exit 1)
	@echo "OK: no suspicious credential artifacts in bundle"

# Ad-hoc signed arm64 zip for GitHub Releases (not notarized).
release-zip: app
	@test -d "$(APP)" || (echo "Missing $(APP)" && exit 1)
	rm -f "$(RELEASE_ZIP)" "$(RELEASE_SHA)"
	ditto -c -k --keepParent "$(APP)" "$(RELEASE_ZIP)"
	shasum -a 256 "$(RELEASE_ZIP)" | awk '{print $$1 "  " "'ClaudeGauge-v$(VERSION)-macOS-arm64.zip'"}' > "$(RELEASE_SHA)"
	@echo "Built: $(RELEASE_ZIP)"
	@echo "Checksum: $(RELEASE_SHA)"
	@cat "$(RELEASE_SHA)"
