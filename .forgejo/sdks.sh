#!/bin/sh
# Provision the pinned Flutter SDKs under build/sdks/flutter for CI.
#
# `toolbox dev bootstrap` does this on a developer machine, but it also
# checks for rootful Podman, which the CI container runners do not have. This
# reads the same three pins bootstrap does - the app's, the daemon's
# toolchain, and the Toolbox app's .fvmrc - and skips an SDK that is already
# provisioned (the cache restores them between runs).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
app=$(sed -n 's/^  sdk_version: *//p' config.yaml | head -1)
daemon=$(sed -n 's/^  toolchain_version: *//p' config.yaml | head -1)
toolbox=$(sed -n 's/.*"flutter": *"\([^"]*\)".*/\1/p' toolbox/app/.fvmrc | head -1)
for version in "$app" "$daemon" "$toolbox"; do
  [ -n "$version" ] || { echo "Could not read a Flutter pin" >&2; exit 1; }
  dir="build/sdks/flutter/$version"
  if [ -x "$dir/bin/flutter" ] && [ -f "$dir/bin/cache/flutter.version.json" ]; then
    echo "Flutter $version is provisioned"
    continue
  fi
  rm -rf "$dir"
  mkdir -p build/sdks/flutter
  git clone --quiet --filter=blob:none --no-checkout https://github.com/flutter/flutter.git "$dir"
  git -C "$dir" checkout --quiet --detach "$version"
  "$dir/bin/flutter" --version
  "$dir/bin/flutter" precache --linux
done
