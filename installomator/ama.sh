# Installomator label for Ama.
#
# Installomator (https://github.com/Installomator/Installomator) installs and updates Mac
# apps from the command line. Each app is defined by a "label" — the case block below.
# (AutoPkg calls these "recipes"; Installomator calls them labels.)
#
# HOW IT WORKS
#   1. Installomator reads the version installed at /Applications/Ama.app
#      (CFBundleShortVersionString).
#   2. This label curls the appcast and pulls out `appNewVersion` (the latest version)
#      and `downloadURL` (the exact package) using xmllint, which ships with macOS —
#      no jq, no Homebrew, nothing to install.
#   3. If installed == appNewVersion, Installomator stops. Otherwise it downloads the
#      pkg, verifies it was signed by Team 674T5RS44U, quits Ama, and installs.
#
# INSTALL THIS LABEL
#   Drop this file into your Installomator label set (fragments/labels/ama.sh) and
#   rebuild Installomator.sh, or paste the case block into your MDM/patch tool's custom
#   labels. Then run:  ./Installomator.sh ama
#
#   If you can't rebuild Installomator, use the self-contained valuesfromarguments
#   updater instead: scripts/installomator/update-ama.sh
#
# HOSTING (one-time)
#   Upload two files, produced by ./build-pkg.sh, to the same directory:
#     Ama.pkg    (the notarized installer, stable name)
#     ama.xml    (the appcast, points at the pkg above)
#   Then set amaFeedURL below to that ama.xml URL. That URL is the only thing
#   Installomator needs — the appcast carries the version and the package URL.

ama)
    name="Ama"
    type="pkg"
    appName="Ama.app"
    versionKey="CFBundleShortVersionString"
    expectedTeamID="674T5RS44U"
    blockingProcesses=( "Ama" )
    amaFeedURL="https://www.capstannetworks.com/ama/ama.xml"
    amaFeed=$(curl -fsL "$amaFeedURL")
    appNewVersion=$(echo "$amaFeed" | xmllint --xpath 'string(//item[1]/title)' - 2>/dev/null)
    downloadURL=$(echo "$amaFeed" | xmllint --xpath 'string(//item[1]/enclosure/@url)' - 2>/dev/null)
    ;;
