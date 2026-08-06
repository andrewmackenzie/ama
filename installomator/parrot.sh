# Installomator label for Parrot.
#
# Installomator (https://github.com/Installomator/Installomator) installs and updates Mac
# apps from the command line. Each app is defined by a "label" — the case block below.
# (AutoPkg calls these "recipes"; Installomator calls them labels.)
#
# HOW IT WORKS
#   1. Installomator reads the version installed at /Applications/Parrot.app
#      (CFBundleShortVersionString).
#   2. This label curls the appcast and pulls out `appNewVersion` (the latest version)
#      and `downloadURL` (the exact package) using xmllint, which ships with macOS —
#      no jq, no Homebrew, nothing to install.
#   3. If installed == appNewVersion, Installomator stops. Otherwise it downloads the
#      pkg, verifies it was signed by Team 674T5RS44U, quits Parrot, and installs.
#
# INSTALL THIS LABEL
#   Drop this file into your Installomator label set (fragments/labels/parrot.sh) and
#   rebuild Installomator.sh, or paste the case block into your MDM/patch tool's custom
#   labels. Then run:  ./Installomator.sh parrot
#
#   If you can't rebuild Installomator, use the self-contained valuesfromarguments
#   updater instead: scripts/installomator/update-parrot.sh
#
# HOSTING (one-time)
#   Upload two files, produced by ./build-pkg.sh, to the same directory:
#     Parrot.pkg    (the notarized installer, stable name)
#     parrot.xml    (the appcast, points at the pkg above)
#   Then set parrotFeedURL below to that parrot.xml URL. That URL is the only thing
#   Installomator needs — the appcast carries the version and the package URL.

parrot)
    name="Parrot"
    type="pkg"
    appName="Parrot.app"
    versionKey="CFBundleShortVersionString"
    expectedTeamID="674T5RS44U"
    blockingProcesses=( "Parrot" )
    parrotFeedURL="https://www.capstannetworks.com/parrot/parrot.xml"
    parrotFeed=$(curl -fsL "$parrotFeedURL")
    appNewVersion=$(echo "$parrotFeed" | xmllint --xpath 'string(//item[1]/title)' - 2>/dev/null)
    downloadURL=$(echo "$parrotFeed" | xmllint --xpath 'string(//item[1]/enclosure/@url)' - 2>/dev/null)
    ;;
