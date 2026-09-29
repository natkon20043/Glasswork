#!/bin/sh
# Builds a release Glasswork and installs it as the one Glasswork.app in /Applications.
#
#   scripts/install.sh
#
# Development builds (build/, build-release/) are kept out of Spotlight and Launchpad, so
# only the installed app shows up.

set -eu

project_folder="$(cd "$(dirname "$0")/.." && pwd)"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

"$project_folder/scripts/package.sh"

echo "Installing to /Applications..."
osascript -e 'tell application "Glasswork" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Glasswork.app
ditto "$project_folder/build-release/Glasswork.app" /Applications/Glasswork.app

echo "Hiding the development copies from Spotlight and Launchpad..."
for folder in "$project_folder/build" "$project_folder/build-release" "$project_folder/dist"; do
    if [ -d "$folder" ]; then
        touch "$folder/.metadata_never_index"
    fi
    if [ -d "$folder/Glasswork.app" ]; then
        "$lsregister" -u "$folder/Glasswork.app" >/dev/null 2>&1 || true
    fi
done
# An old location that no longer exists can still be remembered.
"$lsregister" -u "$HOME/Glasswork/build/Glasswork.app" >/dev/null 2>&1 || true
"$lsregister" -f /Applications/Glasswork.app >/dev/null 2>&1 || true

echo "Done: /Applications/Glasswork.app"
