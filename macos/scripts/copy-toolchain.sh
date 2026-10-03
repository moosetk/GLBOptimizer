#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/toolchain"
rm -rf "$DEST"
mkdir -p "$DEST/lib"

cp "$ROOT/Toolchain/package.json" "$ROOT/Toolchain/package-lock.json" "$DEST/"
cp "$ROOT/Toolchain/"*.mjs "$DEST/"
cp "$ROOT/Toolchain/lib/"*.mjs "$DEST/lib/"

if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
  # Release builds are self-contained: ship dependencies, do not point at the repo.
  if [ ! -d "$ROOT/Toolchain/node_modules/@gltf-transform/core" ]; then
    echo "error: Toolchain/node_modules is missing. Run scripts/setup-toolchain.sh first." >&2
    exit 1
  fi
  rsync -a --delete "$ROOT/Toolchain/node_modules/" "$DEST/node_modules/"
else
  printf '%s\n' "$ROOT/Toolchain" > "$DEST/location.txt"
fi
