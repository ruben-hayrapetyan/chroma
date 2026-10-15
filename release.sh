#!/bin/bash
# Builds Chroma and packages it for a GitHub release as build/Chroma.zip.
#
# Archived with ditto, the tool behind Finder's own Compress, because it keeps
# the bundle's code signature and metadata intact through the round trip.
set -euo pipefail

cd "$(dirname "$0")"

# A release is exactly what's on main. The personal branch adds toggles meant
# only for this Mac, and the build compiles every file in Sources/, tracked or
# not, so an uncommitted edit would ship too. Checked before building, because
# build.sh wipes build/ first.
if [ "$(git rev-parse HEAD)" != "$(git rev-parse --verify --quiet main)" ]; then
  echo "release.sh: on $(git rev-parse --abbrev-ref HEAD), not main. Check out main first." >&2
  exit 1
fi
DIRTY="$(git status --porcelain -- Sources tools build.sh release.sh)"
if [ -n "$DIRTY" ]; then
  echo "release.sh: these uncommitted changes would end up in the release:" >&2
  echo "$DIRTY" >&2
  exit 1
fi

./build.sh

echo "==> Packaging"
ditto -c -k --keepParent build/Chroma.app build/Chroma.zip
shasum -a 256 build/Chroma.zip
echo "==> Packaged build/Chroma.zip from main at $(git rev-parse --short HEAD)"
