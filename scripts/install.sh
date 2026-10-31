#!/bin/sh
# Builds a release Glasswork and installs Glasswork.app and Glasswork Bitmap.app in /Applications.
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
osascript -e 'tell application id "dev.glasswork.Glasswork" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application id "dev.glasswork.GlassworkBitmap" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Glasswork.app "/Applications/Glasswork Bitmap.app"
ditto "$project_folder/build-release/app.noindex/Glasswork.app" /Applications/Glasswork.app
ditto "$project_folder/build-release/app.noindex/Glasswork Bitmap.app" "/Applications/Glasswork Bitmap.app"

echo "Hiding the development copies from Spotlight and Launchpad..."
for folder in "$project_folder/build" "$project_folder/build-release" "$project_folder/dist"; do
    if [ -d "$folder" ]; then
        touch "$folder/.metadata_never_index"
    fi
    for old in "$folder/Glasswork.app" "$folder/app.noindex/Glasswork.app" "$folder/app.noindex/Glasswork Bitmap.app"; do
        if [ -d "$old" ]; then
            "$lsregister" -u "$old" >/dev/null 2>&1 || true
        fi
    done
done
# An old location that no longer exists can still be remembered.
"$lsregister" -u "$HOME/Glasswork/build/Glasswork.app" >/dev/null 2>&1 || true
"$lsregister" -f /Applications/Glasswork.app >/dev/null 2>&1 || true
"$lsregister" -f "/Applications/Glasswork Bitmap.app" >/dev/null 2>&1 || true

echo "Done: /Applications/Glasswork.app and /Applications/Glasswork Bitmap.app"
