#!/bin/sh
# Makes "Glasswork Bitmap.app" from a built Glasswork.app: the same program with its own name,
# bundle identifier and icon, and GWBitmapMode set, which starts it in bitmap mode.
#
#   scripts/make_bitmap_app.sh path/to/Glasswork.app
#
# The new app is written next to the original and signed ad hoc.

set -eu

source_app="$1"
project_folder="$(cd "$(dirname "$0")/.." && pwd)"
bitmap_app="$(dirname "$source_app")/Glasswork Bitmap.app"
plist="$bitmap_app/Contents/Info.plist"
buddy=/usr/libexec/PlistBuddy

rm -rf "$bitmap_app"
ditto "$source_app" "$bitmap_app"
"$buddy" -c "Set :CFBundleIdentifier dev.glasswork.GlassworkBitmap" "$plist"
"$buddy" -c "Set :CFBundleName Glasswork Bitmap" "$plist"
"$buddy" -c "Set :CFBundleDisplayName Glasswork Bitmap" "$plist"
"$buddy" -c "Set :CFBundleIconFile GlassworkBitmap" "$plist"
"$buddy" -c "Add :GWBitmapMode bool true" "$plist"
rm -f "$bitmap_app/Contents/Resources/Glasswork.icns"
cp "$project_folder/resources/GlassworkBitmap.icns" "$bitmap_app/Contents/Resources/GlassworkBitmap.icns"
codesign --force --deep --sign - "$bitmap_app" 2>/dev/null
