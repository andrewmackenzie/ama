# Ama — build the CLI, assemble a regular Mac .app, and (optionally) sign,
# notarize, and package it for distribution.
#
# Quick start:
#   make app        # build + bundle Ama.app (ad-hoc signed, usable now)
#   make run        # launch it
#   make install    # copy to /Applications
#
# Distribution (Capstan Networks Developer ID; certs + notary profile already set up):
#   make pkg        # notarized Ama.pkg + Sparkle appcast in build/dist/
#   make release    # publish the built pkg + appcast to GitHub Releases

APP_NAME    ?= Ama
APP_ID      ?= com.capstannetworks.ama
# Bundle executable name. The SPM product is still built as `parrot` (see BIN);
# it is copied into the bundle as `ama` to match CFBundleExecutable.
EXEC        ?= ama

# Versions derive from the git commit count, like wadlow/sstp, so every build
# gets a fresh auto-incrementing version and Info.plist never needs hand-editing.
# Bump MARKETING_BASE only for a deliberate major/minor release.
MARKETING_BASE ?= 0.1
COMMIT_COUNT   := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
SHORT_VERSION  ?= $(MARKETING_BASE).$(COMMIT_COUNT)
BUILD_VERSION  ?= $(COMMIT_COUNT)

BUILD_DIR   ?= build
BIN         := .build/release/parrot
APP         := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents

# Signing identity for `make sign` (used by `make install`). The .pkg pipeline in
# build-pkg.sh finds the Developer ID Application + Installer certs itself.
DEV_ID  ?= Developer ID Application: Capstan Networks LLC (674T5RS44U)
TEAM_ID ?= 674T5RS44U

.PHONY: all build icon app sign pkg release install run clean

all: app

# --- Compile the Swift executable ------------------------------------------
build:
	swift build -c release

# --- Render the app icon ----------------------------------------------------
icon: $(BUILD_DIR)/AppIcon.icns

$(BUILD_DIR)/AppIcon.icns: scripts/make-icon.swift
	@mkdir -p $(BUILD_DIR)
	swift scripts/make-icon.swift $(BUILD_DIR)/AppIcon.iconset
	iconutil --convert icns $(BUILD_DIR)/AppIcon.iconset --output $@
	@rm -rf $(BUILD_DIR)/AppIcon.iconset

# --- Assemble Ama.app -------------------------------------------------------
# Ad-hoc signed so microphone + accessibility permissions attach immediately.
app: build icon
	@rm -rf $(APP)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN) $(CONTENTS)/MacOS/$(EXEC)
	cp $(BUILD_DIR)/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	cp LICENSE $(CONTENTS)/Resources/LICENSE
	bash scripts/collect-licenses.sh $(CONTENTS)/Resources/THIRD-PARTY-LICENSES.txt
	sed -e 's/__APP_ID__/$(APP_ID)/g' \
		-e 's/__SHORT_VERSION__/$(SHORT_VERSION)/g' \
		-e 's/__BUILD__/$(BUILD_VERSION)/g' \
		packaging/Info.plist > $(CONTENTS)/Info.plist
	codesign --force --sign - \
		--entitlements packaging/Ama.entitlements \
		--identifier $(APP_ID) $(APP)
	@echo "built $(APP)"

# --- Developer ID signing (for distribution) --------------------------------
sign: app
	@test -n "$(DEV_ID)" || (echo "set DEV_ID=\"Developer ID Application: ... (TEAMID)\"" && exit 1)
	codesign --force --options runtime --timestamp \
		--entitlements packaging/Ama.entitlements \
		--identifier $(APP_ID) \
		--sign "$(DEV_ID)" $(APP)
	codesign --verify --deep --strict --verbose=2 $(APP)

# --- Distribution: notarized .pkg + Sparkle appcast -------------------------
# The full sign → pkgbuild → notarize → staple → appcast pipeline lives in
# build-pkg.sh (same two-step build/publish split as wadlow/sstp). Artifacts
# land in build/dist/. `make pkg ARGS=--no-notarize` for fast iteration.
pkg:
	./build-pkg.sh $(ARGS)

# Publish an already-built pkg + appcast to GitHub Releases.
release:
	./release.sh $(ARGS)

# --- Convenience ------------------------------------------------------------
# Install the *Developer ID*-signed app so TCC (accessibility/mic) grants stick.
# Falls back to plain `app` (ad-hoc) automatically if no signing cert is present.
install: sign
	@rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	@echo "installed /Applications/$(APP_NAME).app"

run: app
	open $(APP)

clean:
	rm -rf $(BUILD_DIR)
	swift package clean
