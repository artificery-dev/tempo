#!/bin/sh
# Print a cache key for one component of the pipeline: a hash of the git
# blobs (and submodule pins) of everything its job reads, so a run whose
# inputs match an earlier one restores that run's outputs instead of
# building. Usage: inputs.sh COMPONENT
#
# The workflow file is not an input: a job's steps change rarely, and
# bumping `salt` below invalidates every cache when they do. The image the
# jobs run in is, through config.yaml.
set -eu
component=$1
salt=1

# What every job reads: the build tool, the pins, the SDK provisioning.
common='packages/tempo_build config.yaml pubspec.yaml pubspec.lock .forgejo/sdks.sh .forgejo/inputs.sh'
app='app assets packages/tempo_core packages/player_api packages/daemon_client packages/tempo_logger packages/flutter_pi_plymouth_handoff'
daemon='daemon packages/tempo_data packages/player_api packages/tempo_logger packages/daemon_client packages/tempo_kms Cargo.toml Cargo.lock'
toolbox='toolbox packages/tempo_usb packages/toolbox_core packages/tempo_data packages/tempo_core packages/tempo_logger platform/firmware/DA.img'
recovery='platform/recovery platform/kernel/config platform/firmware platform/rootfs/initramfs/busybox assets/tempo/svg .gitmodules'
kernel='platform/kernel platform/rootfs/initramfs .gitmodules'
splash='platform/splash platform/firmware/stock/logo.bin packages/tempo_core/assets/swirl.png'

case $component in
  check-app | app) paths=$app ;;
  check-daemon | daemon) paths=$daemon ;;
  # The Toolbox ships the Recovery images inside it.
  check-toolbox | toolbox | toolbox-macos) paths="$toolbox $recovery" ;;
  recovery) paths=$recovery ;;
  kernel) paths=$kernel ;;
  splash) paths=$splash ;;
  # cadenced is pinned in config.yaml, which is common to all.
  cadence) paths= ;;
  rootfs) paths="$app $daemon platform/rootfs platform/bluetooth platform/splash/plymouth platform/firmware" ;;
  *) echo "inputs.sh: unknown component $component" >&2; exit 2 ;;
esac

if command -v sha256sum > /dev/null; then digest='sha256sum'; else digest='shasum -a 256'; fi
# shellcheck disable=SC2086
hash=$(git ls-files -s -- $common $paths | $digest | cut -c1-40)
echo "$component-$salt-$hash"
