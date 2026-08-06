#!/usr/bin/env bash
#
# Publish an already-built Parrot to GitHub Releases.
#
# Build and publish are two separate steps on purpose (same as wadlow/sstp): run
# ./build-pkg.sh as often as you like for test builds — nothing goes public. When you
# actually want to ship, run this. It creates (or updates) a GitHub release tagged
# v<version> with the notarized pkg and the appcast attached as assets.
#
# The website repo (capstannetworks-com) pulls those two assets and serves them at
# https://www.capstannetworks.com/parrot/.
#
# Prereqs: gh CLI authenticated (gh auth status), and ./build-pkg.sh already run
# (so build/dist/ holds the notarized Parrot.pkg + parrot.xml).
#
# Usage:
#   ./release.sh              # create/update release v<version>
#   ./release.sh --dry-run    # show what it would do, publish nothing

set -euo pipefail

cd "$(dirname "$0")"

REPO="andrewmackenzie/parrot"
BUILD_DIR="build/dist"
PKG="$BUILD_DIR/Parrot.pkg"
APPCAST="$BUILD_DIR/parrot.xml"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# Artifacts must exist. They are produced by build-pkg.sh; we never build here.
if [[ ! -f "$PKG" || ! -f "$APPCAST" ]]; then
  echo "ERROR: missing $PKG or $APPCAST."
  echo "       Run ./build-pkg.sh first (it produces both in build/dist/)."
  exit 1
fi

# Read the version straight from the appcast, so the tag matches exactly what the
# appcast advertises to Installomator/Sparkle.
SHORT_VERSION=$(xmllint --xpath 'string(//item[1]/title)' "$APPCAST")
BUILD_NUMBER=$(git rev-list --count HEAD)
TAG="v${SHORT_VERSION}"

# A public installer must be notarized + stapled. Fail loudly if the ticket is missing.
echo "==> Validating notarization ticket on the pkg"
xcrun stapler validate "$PKG"

# The tag should capture the exact shipped source, so refuse tracked modifications that
# aren't committed. Untracked files are ignored — they aren't part of the tagged source.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "ERROR: uncommitted changes to tracked files. Commit them first so tag $TAG captures the shipped source."
  git status --short --untracked-files=no
  exit 1
fi
if ! git merge-base --is-ancestor HEAD "@{u}" 2>/dev/null; then
  echo "ERROR: HEAD is not on the remote. Run 'git push' first so the release tag can point at it."
  exit 1
fi

TARGET_SHA=$(git rev-parse HEAD)
TITLE="Parrot ${SHORT_VERSION}"
NOTES="Parrot ${SHORT_VERSION} (build ${BUILD_NUMBER})

- Installer: Parrot.pkg — Developer ID signed, notarized, stapled (Team 674T5RS44U)
- Appcast:   parrot.xml — Sparkle feed, also consumed by Installomator and the website sync

The website (capstannetworks-com) pulls these two assets and serves them at
https://www.capstannetworks.com/parrot/."

RELEASE_EXISTS=false
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  RELEASE_EXISTS=true
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "== DRY RUN =="
  echo "  repo:    $REPO"
  echo "  tag:     $TAG  (target $TARGET_SHA)"
  echo "  action:  $([[ "$RELEASE_EXISTS" == true ]] && echo 'update existing release assets' || echo 'create new release')"
  echo "  assets:  $PKG"
  echo "           $APPCAST"
  exit 0
fi

if [[ "$RELEASE_EXISTS" == "true" ]]; then
  echo "==> Release $TAG exists — updating assets and notes"
  gh release upload "$TAG" "$PKG" "$APPCAST" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "$TITLE" --notes "$NOTES"
else
  echo "==> Creating release $TAG"
  gh release create "$TAG" "$PKG" "$APPCAST" \
    --repo "$REPO" \
    --target "$TARGET_SHA" \
    --title "$TITLE" \
    --notes "$NOTES"
fi

echo ""
echo "Published: https://github.com/$REPO/releases/tag/$TAG"
echo "Next: run the website sync in capstannetworks-com to pull + serve this release."
