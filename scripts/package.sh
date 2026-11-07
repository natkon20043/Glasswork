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

app="$build_folder/app.noindex/Glasswork.app"

# VS Code extensions run in a Node.js process. Ship one inside the app so extensions work on
# a Mac without Node installed (the app prefers it to any Node on the PATH). Skip with
# GLASSWORK_BUNDLE_NODE=0, or point GLASSWORK_NODE_BINARY at the Node to use.
if [ "${GLASSWORK_BUNDLE_NODE:-1}" != "0" ]; then
    node_binary="${GLASSWORK_NODE_BINARY:-$(command -v node || true)}"
    if [ -n "$node_binary" ] && [ -x "$node_binary" ]; then
        echo "Bundling Node.js from $node_binary ($("$node_binary" --version))..."
        cp "$node_binary" "$app/Contents/Resources/node"
        codesign --force --sign - "$app/Contents/Resources/node"
    else
        echo "No Node.js found to bundle: extensions will need Node installed on the Mac."
    fi
fi

echo "Signing (ad hoc)..."
codesign --force --deep --sign - "$app"

echo "Zipping..."
mkdir -p "$dist_folder"
rm -f "$dist_folder/Glasswork.zip"
ditto -c -k --keepParent "$app" "$dist_folder/Glasswork.zip"

echo "Done: $dist_folder/Glasswork.zip"
