# Kernel

Tempo runs mainline Linux on the MT6582. The source lives in a fork of the
kernel at <https://github.com/artificery-dev/linux>, on the branch
`tempo/innioasis-y2`, which carries the Y2 drivers and device tree on top of an
unmodified Linux v6.12 base. The Tempo repository pins one exact commit of that
branch as the `platform/kernel/linux` submodule and builds it with a product
configuration fragment merged over `multi_v7_defconfig`. The result is a single
`boot.img` for the `BOOTIMG` partition: the zImage with its appended device
tree, and an initramfs that hands off to the Debian root filesystem.

## Components

| Where | What |
| --- | --- |
| `platform/kernel/linux` | The kernel fork, as a shallow submodule pinned to one commit of `tempo/innioasis-y2`. |
| `platform/kernel/README.md` | The fork, base version and the driver change workflow in short form. |
| `platform/kernel/config/y2.config` | The product configuration fragment, with a comment above each group explaining why it is set. |
| `platform/kernel/tool/build.dart`, `prepare.dart`, `bootimg.dart` | Entry points that forward to `toolbox dev os kernel`. |
| `packages/tempo_build/lib/src/kernel.dart` | `KernelSource` provenance, the initramfs renderer and builder, the `mtkHeader` and `bootImage` packers, and `kernelCommand`. |
| `platform/rootfs/initramfs/init.in`, `initramfs.list` | The initramfs `/init` template and the built-in cpio manifest. |
| `platform/rootfs/initramfs/busybox/busybox-armv7l` | The static BusyBox the initramfs runs. |
| `platform/firmware/mediatek/mt6582/` | CONSYS and FM firmware compiled into the kernel through `CONFIG_EXTRA_FIRMWARE`. |
| `packages/tempo_build/lib/src/distribution.dart` | `toolbox dev dist`: checks `boot.img`, packages it and records kernel provenance. |
| `build/os/kernel/`, `build/os/initramfs/` | The `O=` build tree with `tempo-source.json`, `y2.config` and `boot.img`; the rendered `init`, both manifests and `initramfs.cpio.gz`. |

## The fork and the pin

The fork's `master` is the unmodified Linux v6.12 base, commit
`adc218676eef25575469234709c2d87185ca223a`. Everything Tempo adds sits on
`tempo/innioasis-y2` as ordinary commits, so the kernel history itself records
the driver and device-tree changes. There is no patch stack in the Tempo
repository and the build never applies one.

`.gitmodules` names the branch and marks the submodule `shallow`, and bootstrap
initialises it with `git submodule update --init --recursive --depth 1`. The
pin is the submodule commit recorded in Tempo's own history. Ordinary builds
use exactly that commit; `git submodule update --remote` is not part of any
build step, because it would silently move the pin.

```sh
git submodule update --init platform/kernel/linux
toolbox dev os kernel build
```

## Commands

`toolbox dev os kernel` has six actions. `platform/kernel/tool/*.dart` are thin
wrappers around the same routes.

| Action | What it does |
| --- | --- |
| `build` | Prepare, render the initramfs, configure and compile the zImage and DTB, build the external initramfs, then pack `boot.img`. |
| `prepare` | Verify the submodule checkout is committed and record its provenance. |
| `bootimg` | Pack an existing build into `boot.img`; accepts `--dtb`, `--ramdisk`, `--output` and `--max-size`. |
| `rev` | Print the submodule's current commit. |
| `reset` | Delete the provenance record. Refuses if the checkout has uncommitted changes, and never touches the source. |
| `clean` | Remove `build/os/kernel` and `build/os/initramfs`. The checkout is left alone. |

Within `toolbox dev build`, `os kernel build` runs after `os rootfs build`,
because the rootfs build produces the Plymouth payload the initramfs packs.

## Provenance

`KernelSource.prepare` hashes the tracked diff against `HEAD` together with
every untracked file, including file modes and symlink targets. If the diff or
the untracked list is non-empty the build stops, with no source changed: the
developer is expected to commit in the fork first. The Y2 device tree must be
present at `arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts`, which is how
a checkout of the wrong branch is caught. The record is written to
`build/os/kernel/tempo-source.json`:

| Field | Value |
| --- | --- |
| `base` | The commit of `HEAD`. |
| `tree` | The tree ID of `HEAD`. |
| `source.sha256` | The hash of the diff and untracked files. |
| `source.untracked` | The untracked file names. |

`toolbox dev dist` copies this record into `build-provenance.json`, with the
submodule commit and the SHA-256 of the final `.config`.

## Configuration

`y2.config` is a Kconfig fragment, not a full `.config`. The build copies it to
`build/os/kernel/y2.config`, substitutes `@ROOT@` with the checkout root and
redirects `CONFIG_INITRAMFS_SOURCE` at the rendered manifest under
`build/os/initramfs`. It then runs `make multi_v7_defconfig` with
`O=build/os/kernel`, appends the fragment to `.config`, runs `olddefconfig`, and
builds `zImage` and `mediatek/mt6582-innioasis-y2.dtb`. All of that runs in
the [toolchain container](toolchain.md), which sets `ARCH=arm` and
`CROSS_COMPILE=arm-linux-gnueabihf-`.

The fragment is organised by subsystem, and the comments carry the reasoning.
The decisions that shape the whole image are:

- **Everything is built in.** The rootfs installs no modules tree.
  `CONFIG_MODULES` stays on only because turning it off makes `olddefconfig`
  promote the defconfig's `=m` entries to `=y` and grows the image.
- **The command line is forced.** `CONFIG_CMDLINE_FORCE` replaces whatever LK
  passes with `console=ttyS0,921600n8 quiet splash
  plymouth.ignore-serial-consoles drm_kms_helper.fbdev_emulation=0 rootwait
  clk_ignore_unused`. `CONFIG_ARM_APPENDED_DTB` takes the device tree from the
  end of the zImage, and `CONFIG_ARM_ATAG_DTB_COMPAT` is off so LK's atags are
  never merged into it.
- **Firmware is compiled in.** `CONFIG_EXTRA_FIRMWARE` names the two WMT patch
  images, the WiFi RAM code, `WMT_SOC.cfg` and the MT6627 FM patch,
  coefficients and tuning, taken from `platform/firmware`. A flashed kernel is
  self-contained; see [Firmware inputs](firmware-inputs.md).
- **The BOOTIMG budget is 16 MiB.** `device.partitions.bootimg_size` in
  `config.yaml` is the limit the packer enforces, so subsystems the device does
  not have stay off.
- **No suspend, no cpufreq, no cpuidle.** `CONFIG_PM`, `CONFIG_SUSPEND`,
  `CONFIG_CPU_FREQ` and `CONFIG_CPU_IDLE` are all off.
- `CONFIG_HZ_1000`, `CONFIG_HIGHMEM` for the 992 MB of DRAM, 16 MB of CMA for
  display buffers, `CONFIG_KEXEC`, `CONFIG_DEVMEM` without `STRICT_DEVMEM`,
  and `CONFIG_IKCONFIG_PROC` so a running device exposes its configuration at
  `/proc/config.gz`.
- The netfilter set is what `ufw` reaches through `nft_compat`, and the
  namespace, cgroup and BPF options are what systemd's sandboxing directives
  need.

## Initramfs and the boot image

There are two initramfs archives. The built-in one comes from
`initramfs.list` through `CONFIG_INITRAMFS_SOURCE` and holds only the device
nodes, `/proc`, `/sys`, BusyBox and `/init`. The external one is built by
`buildInitramfs` and is what `boot.img` actually carries as its ramdisk.

`renderInitramfs` substitutes `@HOSTNAME@`, `@ROOTFS_SIZE_MB@`, `@ROOT@` and
`@INIT@` from `config.yaml` into `init.in` and `initramfs.list`, writing the
results to `build/os/initramfs`. A leftover placeholder fails the build.
`buildInitramfs` then compiles `usr/gen_init_cpio` from the kernel tree if it
is missing, writes `external.list` with the same base entries plus every file
under `build/os/rootfs/plymouth-payload` when that directory exists, refreshes
the theme files in that payload from `platform/splash/plymouth/tempo`, and
produces `initramfs.cpio.gz` at gzip level 9. The payload is how the splash
comes up before the root filesystem; see [Boot splash](splash.md).

`/init` mounts the pseudo filesystems, starts `plymouthd` as soon as
`/dev/dri/card0` appears, and then either mounts `/dev/mmcblk0p1` and
`switch_root`s into it, installs a `<hostname>.ext4` or `.ext4.gz` image found
on the microSD onto that partition with progress on the splash, or drops to a
shell. The partition layout it relies on is described in
[Boot and flashing](boot-and-flashing.md).

The `bootimg` step packs the pieces in `kernel.dart`:

1. Read `arch/arm/boot/zImage` and the DTB from `build/os/kernel`.
2. If a ramdisk exists, copy the DTB and set `/chosen/linux,initrd-start` to
   `0x84000000` and `linux,initrd-end` to that address plus the ramdisk length,
   with `fdtput`.
   Without one, a nine-page placeholder ramdisk is used.
3. Wrap the zImage plus DTB in a 512-byte MediaTek header named `KERNEL`, and
   the ramdisk in one named `ROOTFS`.
4. Write an Android boot header with a 2048-byte page size, kernel load
   address `0x10008000`, ramdisk address `0x11000000` and tags address
   `0x10000100`, followed by the two page-aligned payloads.
5. Refuse an image larger than `device.partitions.bootimg_size` and write
   `build/os/kernel/boot.img`, printing the bytes left.

`toolbox dev dist` checks the `ANDROID!` magic and the size again before
copying `boot.img` into `build/dist/images` and the SPFT set, and
`toolbox dev device flash-boot` writes it to a running device at
`device.partitions.bootimg_offset`.

## Changing a driver

Driver and device-tree work happens in the fork, not in Tempo.

1. Edit under `platform/kernel/linux` on `tempo/innioasis-y2`.
2. Commit there. `toolbox dev os kernel build` refuses an uncommitted tree, so
   a build is always of a commit that exists.
3. Build, flash with `toolbox dev device flash-boot`, and test.
4. Push the fork branch, then commit the moved submodule pointer in Tempo.

`toolbox dev os kernel rev` prints the commit currently checked out.
`toolbox dev device collect-sysinfo` captures the running kernel's
`/proc/config.gz`, device tree and probe state for comparison; see
[Diagnostics](diagnostics.md).

## What the fork adds

The branch changes a small set of subsystems, in most cases as variants of the
existing MediaTek drivers rather than new ones. The board file
`mt6582-innioasis-y2.dts` declares `innioasis,y2` on `mediatek,mt6582`, the
992 MB memory node, the reserved CONSYS EMI window at the top of DRAM and
`mediatek,mt6589-smp` as the enable method for all four Cortex-A7 cores.

| Area | In the fork | Page |
| --- | --- | --- |
| Machine and clocks | `arch/arm/mach-mediatek` for the MT6582 and its SMP release, `drivers/clk/mediatek/clk-mt6582*.c` for apmixedsys, topckgen, infracfg, pericfg and the mmsys gates, `drivers/soc/mediatek/mt6582-spm.c` for the SPM firmware. | |
| Display and GPU | MT6582 compatibles across `drivers/gpu/drm/mediatek`, `panel-gc9503v.c`, the MIPI DSI PHY, `mt6582-mfg-power.c` for the Mali power domain used by lima, and a darker VT palette in `drivers/tty/vt/vt.c`. | [Display](../porting/display.md) |
| Input | `gpio-mt6582.c` with EINT, `apt32f-wheel.c` for the click wheel, `mt6582-keypad.c` for the volume keys, and a change to `mtk-pmic-keys.c` for the power key. | [Input](../porting/input.md) |
| Audio | `sound/soc/mediatek/mt6582` for the AFE, the `mt6582-cs43131` machine driver and the `aw87559` amplifier codec. | [Audio](../porting/audio.md) |
| Power | `mtk-pmic-wrap.c` for the MT6582 pwrap, `mt6323-charger.c` and `mt6323-backlight.c`. The MT6323 regulators, RTC, power key and poweroff are mainline drivers under the `mt6397` MFD, enabled by the configuration. | [Power Management](../porting/power.md) |
| Storage | Optional pinctrl in `drivers/mmc/host/mtk-sd.c`, so eMMC and microSD probe without an MT6582 pinctrl driver. | [Storage](../porting/storage.md) |
| USB | `phy-mtk-u2-mt6582.c` behind the mainline MUSB glue, giving the CDC serial and ethernet gadget. | |
| Connectivity | `drivers/misc/mediatek-consys`: the WMT and STP stack over BTIF, an `hci` driver for BlueZ, the full-MAC WiFi driver on cfg80211, and the MT6627 FM receiver. | [Wifi](../porting/wifi.md), [Bluetooth](../porting/bluetooth.md), [FM](../porting/fm.md) |

The connectivity hardware also depends on a userspace step before the drivers
start; see [Radio initialization](radio-initialization.md).
