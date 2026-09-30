#!/bin/sh
# Builds a release Glasswork.app, signs it ad hoc and zips it into dist/Glasswork.zip.
#
#   scripts/package.sh
#
# The ad-hoc signature lets the app run on this Mac. To share it with others it needs a
# Developer ID certificate and notarization; that is deliberately not done here, so no
# personal certificate ends up inside a build.

set -eu

project_folder="$(cd "$(dirname "$0")/.." && pwd)"
build_folder="$project_folder/build-release"
dist_folder="$project_folder/dist"

echo "Configuring a release build..."
cmake -S "$project_folder" -B "$build_folder" -G Ninja -DCMAKE_BUILD_TYPE=Release

echo "Building..."
cmake --build "$build_folder" --target Glasswork

echo "Running the tests..."
cmake --build "$build_folder"
ctest --test-dir "$build_folder" --output-on-failure

echo "Signing (ad hoc)..."
codesign --force --deep --sign - "$build_folder/app.noindex/Glasswork.app"

echo "Zipping..."
mkdir -p "$dist_folder"
rm -f "$dist_folder/Glasswork.zip"
ditto -c -k --keepParent "$build_folder/app.noindex/Glasswork.app" "$dist_folder/Glasswork.zip"

echo "Done: $dist_folder/Glasswork.zip"
