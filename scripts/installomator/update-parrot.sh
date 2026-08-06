#!/bin/sh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# ---------------------------------------
# This script detects IF Parrot is installed and, if so, updates it as needed
# via Installomator.
#
# Latest version + package URL come from the Parrot Sparkle appcast (also
# consumed by the `parrot` Installomator label). Parrot is not a built-in
# Installomator label, so this runs the self-contained `valuesfromarguments`
# label and passes the values pulled from the appcast.
# Only depends on curl + xmllint, both of which ship with macOS.
#
# Deploy via MDM as a script/policy. It is safe to run repeatedly: it no-ops
# when Parrot is absent or already current.
# ---------------------------------------

# ---------------------------------------
# Variables you can change
# ---------------------------------------

app_path="/Applications/Parrot.app"
feed_url="https://www.capstannetworks.com/parrot/parrot.xml"
version_detection_key="CFBundleShortVersionString"
expected_team_id="674T5RS44U"

# ------------------------------------------------------
# Check for root
# ------------------------------------------------------

if [ "$(id -u)" != 0 ]; then
    sudo "$0" "$@"
    exit $?
fi

# ---------------------------------------
# Variables to leave alone
# ---------------------------------------
app_name="$(basename "$app_path")"

# ---------------------------------------
# Functions
# ---------------------------------------
Update_or_Install_Installomator() {
    echo "Checking for Installomator"
    if [ ! -f /usr/local/Installomator/Installomator.sh ] ; then
        echo "Installomator not installed"
        installed_installomator_version="NOT-INSTALLED"
    else
        installed_installomator_version="$(awk -F '"' '/VERSION=/ { print $2 }' /usr/local/Installomator/Installomator.sh)"
        echo "Installomator version $installed_installomator_version installed"
    fi
    latest_installomator_version="$(curl -L --silent --fail "https://api.github.com/repos/Installomator/Installomator/releases/latest" | grep tag_name | cut -d '"' -f 4 | sed 's/[^0-9\.]//g')"
    if [ "$latest_installomator_version" != "$installed_installomator_version" ] ; then
        echo "Installomator $installed_installomator_version needs update to $latest_installomator_version"
        curl --location --output /tmp/installomator-latest.pkg "$(curl --silent --location https://api.github.com/repos/installomator/installomator/releases/latest | awk -F '"' '/browser_download_url/ { print $4 }')" && installer -verbose -pkg /tmp/installomator-latest.pkg -target /
    fi
}

# ---------------------------------------
# Main Script
# ---------------------------------------

# Only update an app that is already installed; never first-install here.
if [ -d "$app_path" ] ; then
    echo "$app_path exists. Checking for updates."
    parrot_feed=$(curl --silent --location --fail "$feed_url")
    latest_app_version=$(echo "$parrot_feed" | xmllint --xpath 'string(//item[1]/title)' - 2>/dev/null)
    download_url=$(echo "$parrot_feed" | xmllint --xpath 'string(//item[1]/enclosure/@url)' - 2>/dev/null)
    installed_app_version=$(defaults read "$app_path/Contents/Info.plist" "$version_detection_key")

    if [ "$latest_app_version" != "$installed_app_version" ] ; then
        Update_or_Install_Installomator
        echo "$app_name $installed_app_version needs update to $latest_app_version"

        # Values passed to the valuesfromarguments label. Parrot's name and process
        # have no spaces, so no quote-escaping gymnastics are needed (unlike "Warren VPN").
        /usr/local/Installomator/Installomator.sh valuesfromarguments \
            name="Parrot" \
            type="pkg" \
            downloadURL="$download_url" \
            appNewVersion="$latest_app_version" \
            expectedTeamID="$expected_team_id" \
            blockingProcesses="Parrot"
    else
        echo "$app_name $installed_app_version is up to date. Exiting."
    fi
else
    echo "$app_path not installed. Exiting."
fi
