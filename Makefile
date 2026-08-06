# Parrot — build the CLI, assemble a regular Mac .app, and (optionally) sign,
# notarize, and package it for distribution.
#
# Quick start:
#   make app        # build + bundle Parrot.app (ad-hoc signed, usable now)
#   make run        # launch it
#   make install    # copy to /Applications
#
# Distribution (needs an Apple Developer account):
#   make sign DEV_ID="Developer ID Application: Your Name (TEAMID)"
#   make notarize NOTARY_PROFILE="parrot-notary"
#   make dmg

APP_NAME    ?= Parrot
APP_ID      ?= com.digimata.parrot
VERSION     ?= 0.1.0
BUILD_DIR   ?= build
BIN         := .build/release/parrot
APP         := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents

# For `make sign` / `make notarize`. Defaults to the Capstan Networks Developer
# ID; override on the command line to use a different signing identity.
DEV_ID         ?= Developer ID Application: Capstan Networks LLC (674T5RS44U)
TEAM_ID        ?= 674T5RS44U
NOTARY_PROFILE ?= parrot-notary

.PHONY: all build icon app sign notarize dmg install run clean

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

# --- Assemble Parrot.app ----------------------------------------------------
# Ad-hoc signed so microphone + accessibility permissions attach immediately.
app: build icon
	@rm -rf $(APP)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN) $(CONTENTS)/MacOS/parrot
	cp $(BUILD_DIR)/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	sed -e 's/__APP_ID__/$(APP_ID)/g' -e 's/__VERSION__/$(VERSION)/g' \
		packaging/Info.plist > $(CONTENTS)/Info.plist
	codesign --force --sign - \
		--entitlements packaging/Parrot.entitlements \
		--identifier $(APP_ID) $(APP)
	@echo "built $(APP)"

# --- Developer ID signing (for distribution) --------------------------------
sign: app
	@test -n "$(DEV_ID)" || (echo "set DEV_ID=\"Developer ID Application: ... (TEAMID)\"" && exit 1)
	codesign --force --options runtime --timestamp \
		--entitlements packaging/Parrot.entitlements \
		--identifier $(APP_ID) \
		--sign "$(DEV_ID)" $(APP)
	codesign --verify --deep --strict --verbose=2 $(APP)

# --- Notarization -----------------------------------------------------------
notarize:
	@test -n "$(NOTARY_PROFILE)" || (echo "set NOTARY_PROFILE=<notarytool keychain profile>" && exit 1)
	ditto -c -k --keepParent $(APP) $(BUILD_DIR)/$(APP_NAME).zip
	xcrun notarytool submit $(BUILD_DIR)/$(APP_NAME).zip \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP)

# --- DMG --------------------------------------------------------------------
dmg: app
	@rm -rf $(BUILD_DIR)/dmg $(BUILD_DIR)/$(APP_NAME).dmg
	@mkdir -p $(BUILD_DIR)/dmg
	cp -R $(APP) $(BUILD_DIR)/dmg/
	ln -s /Applications $(BUILD_DIR)/dmg/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(BUILD_DIR)/dmg \
		-ov -format UDZO $(BUILD_DIR)/$(APP_NAME).dmg
	@rm -rf $(BUILD_DIR)/dmg
	@echo "built $(BUILD_DIR)/$(APP_NAME).dmg"

# --- Convenience ------------------------------------------------------------
install: app
	@rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	@echo "installed /Applications/$(APP_NAME).app"

run: app
	open $(APP)

clean:
	rm -rf $(BUILD_DIR)
	swift package clean
