#!/usr/bin/env bash
#
# Generate the Ama appcast: a small Sparkle-format XML that advertises the
# latest release. Two consumers read it, both with tools already on every Mac:
#
#   - Installomator (and the MDM/patch tools built on it) curls it and parses the
#     version + package URL with the built-in `xmllint`. See installomator/ama.sh
#     and scripts/installomator/update-ama.sh.
#   - Sparkle, if/when Ama wires up in-app auto-update, reads the exact same file.
#
# The file answers the three things a version-check needs:
#   - latest version           -> <item><title> and <sparkle:shortVersionString>
#   - where to download it      -> <item><enclosure url="...">
#   - how to read the installed version locally -> <ama:bundleIdentifier> +
#     <ama:installPath> + <ama:versionKey>
#
# Usage: make-appcast.sh <shortVersion> <build> <packageURL> <outfile>

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <shortVersion> <build> <packageURL> <outfile>" >&2
  exit 2
fi

SHORT_VERSION="$1"
BUILD="$2"
PKG_URL="$3"
OUTFILE="$4"

PUBDATE="$(date "+%a, %d %b %Y %H:%M:%S %z")"

cat > "$OUTFILE" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:ama="https://capstannetworks.com/ama/ns">
  <channel>
    <title>Ama</title>
    <description>Latest Ama release. Sparkle appcast, also consumed by Installomator.</description>
    <language>en</language>

    <!-- How to read the version that is installed locally. Installomator finds the app
         via appName + versionKey; these fields document it for any other tool. -->
    <ama:bundleIdentifier>com.capstannetworks.ama</ama:bundleIdentifier>
    <ama:installPath>/Applications/Ama.app</ama:installPath>
    <ama:versionKey>CFBundleShortVersionString</ama:versionKey>
    <ama:expectedTeamID>674T5RS44U</ama:expectedTeamID>

    <item>
      <title>${SHORT_VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${PKG_URL}"
                 sparkle:version="${BUILD}"
                 sparkle:shortVersionString="${SHORT_VERSION}"
                 type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

echo "    Wrote appcast: $OUTFILE (version $SHORT_VERSION build $BUILD)"
