#!/usr/bin/env bash
#
# Build, sign, notarize, and staple the Ama installer, then emit the
# distribution artifacts (stable-named pkg + Sparkle/Installomator appcast).
# This is the BUILD step only — it never publishes anything. Publishing to
# GitHub Releases is the separate, deliberate ./release.sh step. Same two-step
# split as wadlow and Warren VPN (../sstp). Follows
# ~/Documents/macos-developer-id-distribution-pipeline.md.
#
# Prerequisites (one-time, already set up for Capstan Networks):
#   - Developer ID Application + Developer ID Installer certs in the login
#     keychain (Capstan Networks LLC, team 674T5RS44U)
#   - Notarytool credentials stored as "warren-notarytool" (team-wide profile,
#     shared with wadlow/warrenvpn)
#
# Usage:
#   ./build-pkg.sh                # full pipeline: build, sign, notarize, staple
#   ./build-pkg.sh --no-notarize  # everything except notarize/staple (fast iteration)
#
# Produces in build/dist/ (build only, nothing public):
#   Ama.pkg   — notarized installer, stable name (website serves it at a fixed URL)
#   ama.xml   — appcast; its <enclosure url> = ${DOWNLOAD_BASE_URL}/Ama.pkg

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Ama"
APP_BUNDLE="${APP_NAME}.app"
APP_BUNDLE_ID="com.capstannetworks.ama"
TEAM_ID="674T5RS44U"
NOTARY_PROFILE="${AMA_NOTARY_PROFILE:-warren-notarytool}"
ENTITLEMENTS="packaging/Ama.entitlements"
# Where the pkg + appcast get hosted. The Installomator label and Sparkle both
# read the appcast from ${DOWNLOAD_BASE_URL}/ama.xml, whose enclosure points at
# ${DOWNLOAD_BASE_URL}/Ama.pkg. Override via env to point at a different host.
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://www.capstannetworks.com/ama}"

BUILD_DIR="build/dist"
EXPORT_PATH="$BUILD_DIR/export"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# The signed staging copy under build/dist/export carries Ama's bundle id.
# Left on disk it registers with Launch Services and competes with the installed
# /Applications copy. Remove it on exit; the finished .pkg in build/dist is untouched.
cleanup_staging() {
    if [[ -d "$EXPORT_PATH" ]]; then
        "$LSREGISTER" -u "${APP_PATH:-$EXPORT_PATH/$APP_BUNDLE}" 2>/dev/null || true
        rm -rf "$EXPORT_PATH"
    fi
}
trap cleanup_staging EXIT

NOTARIZE=true
if [[ "${1:-}" == "--no-notarize" ]]; then
    NOTARIZE=false
fi

echo "==> Checking for active VPN tunnels"
if scutil --nwi | grep -q utun; then
    echo "ERROR: active VPN tunnel detected. notary.apple.com TLS will fail."
    echo "       Disconnect and retry."
    exit 1
fi

echo "==> Verifying signing identities"
APP_IDENTITY=$(security find-identity -v | grep "Developer ID Application" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
INSTALLER_IDENTITY=$(security find-identity -v | grep "Developer ID Installer" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
if [[ -z "$APP_IDENTITY" ]]; then
    echo "ERROR: 'Developer ID Application' cert not found."; exit 1
fi
if [[ -z "$INSTALLER_IDENTITY" ]]; then
    echo "ERROR: 'Developer ID Installer' cert not found."; exit 1
fi
echo "    App:       $APP_IDENTITY"
echo "    Installer: $INSTALLER_IDENTITY"

echo "==> Building $APP_BUNDLE (make app)"
make app

VERSION=$(defaults read "$PWD/build/$APP_BUNDLE/Contents/Info.plist" CFBundleShortVersionString)
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
# Stable pkg name (no version in filename): the website serves it at a fixed URL and the
# appcast enclosure points at it. The version lives inside the pkg, the appcast, and the tag.
PKG_PATH="$BUILD_DIR/${APP_NAME}.pkg"

rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_PATH"
cp -R "build/$APP_BUNDLE" "$EXPORT_PATH/$APP_BUNDLE"
APP_PATH="$EXPORT_PATH/$APP_BUNDLE"

echo "==> Signing $APP_BUNDLE with Developer ID (hardened runtime + mic entitlement)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --identifier "$APP_BUNDLE_ID" \
    --sign "$APP_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Building signed .pkg"
# productbuild --component hard-codes BundleIsRelocatable=true, which makes macOS
# upgrade any stray Ama.app on disk instead of installing to /Applications.
# pkgbuild + component-plist with BundleIsRelocatable=false pins the location.
COMPONENT_PLIST="$BUILD_DIR/component.plist"
cat > "$COMPONENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>RootRelativeBundlePath</key>
        <string>$APP_BUNDLE</string>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleIsVersionChecked</key>
        <true/>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
    </dict>
</array>
</plist>
EOF

pkgbuild \
    --root "$EXPORT_PATH" \
    --install-location /Applications \
    --component-plist "$COMPONENT_PLIST" \
    --identifier "$APP_BUNDLE_ID" \
    --version "$VERSION" \
    --sign "$INSTALLER_IDENTITY" \
    "$PKG_PATH"

# Emit the appcast next to the pkg. Writes to build/dist/ only; publishing is the
# separate ./release.sh step. Call only after the pkg is final.
emit_dist_artifacts() {
    echo "==> Generating appcast"
    ./make-appcast.sh \
        "$VERSION" "$BUILD_NUMBER" \
        "${DOWNLOAD_BASE_URL%/}/${APP_NAME}.pkg" \
        "$BUILD_DIR/ama.xml"
    echo "    Built, NOT published. To publish this version to GitHub: ./release.sh"
}

if [[ "$NOTARIZE" == "false" ]]; then
    emit_dist_artifacts
    echo ""
    echo "Done (unnotarized): $PKG_PATH"
    exit 0
fi

echo "==> Submitting to notary service (2-10 min)"
xcrun notarytool submit "$PKG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$PKG_PATH"
xcrun stapler validate "$PKG_PATH"
spctl --assess --type install --verbose "$PKG_PATH"

emit_dist_artifacts

echo ""
echo "Done: $PKG_PATH"
