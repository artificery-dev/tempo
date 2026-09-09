# Tempo Y2 kernel

The `linux/` submodule uses `https://github.com/artificery-dev/linux.git`.
Its `tempo/innioasis-y2` branch contains the drivers and device tree. Fork
`master` is the unmodified Linux **v6.12** base, commit
`adc218676eef25575469234709c2d87185ca223a`. This is the exact base used for the
hardware-tested firmware, not a migration to a newer 6.12.y point release.

Tempo pins an exact submodule commit. Ordinary setup follows that pin:

```sh
git submodule update --init platform/kernel/linux
dart run toolbox/cli/bin/toolbox.dart dev os kernel build
```

`config/y2.config` is the product configuration. Kernel source, including
`arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts`, belongs in the fork. Builds
verify that its checkout is clean and record the commit/tree IDs under
`build/os/kernel/tempo-source.json`. They do not apply patches or discard edits.
The `reset` command clears provenance only; `clean` removes generated output.

To change a driver, commit and push it on `tempo/innioasis-y2`, test it, then
commit the updated submodule pointer in Tempo. Preserve the tracked pin during
ordinary builds; do not use `submodule update --remote` as a build step.

The migration to the fork preserved the complete hardware-tested source tree
byte for byte. The kernel history contains the driver and device-tree changes.
