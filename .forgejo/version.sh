#!/bin/sh
# Print the package version for this build: the config.yaml version, which a
# `v*` tag must match exactly, or that version with a snapshot suffix.
set -eu
base=$(sed -n 's/^version: *//p' config.yaml | head -1)
case "${GITHUB_REF:-}" in
  refs/tags/v*)
    version=${GITHUB_REF#refs/tags/v}
    if [ "$version" != "$base" ]; then
      echo "::error::Tag v$version does not match config.yaml version $base" >&2
      exit 1
    fi
    ;;
  *)
    version="$base~git$(date -u +%Y%m%d).$(printf %.7s "${GITHUB_SHA:-$(git rev-parse HEAD)}")"
    ;;
esac
echo "$version"
