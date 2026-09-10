#!/bin/sh
# Print the short digest that names the toolchain image in CI.
#
# The image is built from this directory alone (its Containerfile copies
# nothing from the checkout), so its identity is this directory's contents.
# .forgejo/workflows/ci.yml computes the same digest to find or push the
# image in the Forgejo registry; a change here rebuilds it on the next run.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
find platform/toolchain -type f -not -name '.*' \
  | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-12
