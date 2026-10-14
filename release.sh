#!/bin/bash
# Builds Chroma and packages it for a GitHub release as build/Chroma.zip.
#
# Archived with ditto, the tool behind Finder's own Compress, because it keeps
# the bundle's code signature and metadata intact through the round trip.
set -euo pipefail

cd "$(dirname "$0")"

./build.sh

echo "==> Packaging"
ditto -c -k --keepParent build/Chroma.app build/Chroma.zip
shasum -a 256 build/Chroma.zip
echo "==> Packaged build/Chroma.zip"
