# Boot splash

The Y2 shows one picture from power-on until the player paints: the Debian
swirl on a black field, 480x360, the panel's own size. The bootloader draws it
from the `LOGO` partition, plymouth redraws it from the initramfs and adds an
orbiting ring of dots, and the app's first frame is the same picture again.
Nothing moves between the three owners; only the throbber appears and
disappears, and the hand-off is timed to the app's first frame.

## Components

| Where | What |
| --- | --- |
| `platform/splash/assets/openlogo-nd.svg` | The upstream Debian Open Use Logo, with its licence beside it. |
| `platform/splash/assets/boot-logo.png` | The rendered 480x360 picture the `LOGO` partition holds. |
| `platform/splash/plymouth/tempo/` | The plymouth theme: `tempo.plymouth`, `tempo.script`, `logo.png`, `dot.png`, `bar.png`. |
| `packages/tempo_build/lib/src/splash.dart` | `LogoImage`, the RGB565 packer, asset rendering, and the `splash` command. |
| `packages/tempo_build/lib/src/plymouth.dart` | `stagePlymouth`: collects the plymouth runtime and its ELF dependency closure from a rootfs tree. |
| `packages/tempo_build/lib/src/kernel.dart` | Packs the staged plymouth payload into the kernel's initramfs. |
| `platform/rootfs/initramfs/init.in` | Starts `plymouthd` seconds into boot, before the root filesystem. |
| `packages/toolbox_core/lib/live_device.dart` | `locateLogo` and `flashLogo`: the header scan and the guarded write on a running device. |
| `packages/flutter_pi_plymouth_handoff/` | `PlymouthHandoff.armOnFirstFrame()`, the Dart side of the hand-off. |
| `app/flutter-pi/plugins/plymouth_handoff.c` | The flutter-pi plugin that asks `tempod` to take the display. |
| `daemon/native/src/handoff.rs` | The privileged half in `tempod`: fade, deactivate, set master, retire plymouth. |
| `config.yaml` `device.partitions.logo_size`, `logo_scan_size` | The partition size and how far the header scan looks. |

## The LOGO partition

The partition holds a standard MTK bootloader image. A 512-byte header carries
the magic, the body size and the name, padded with `0xff`. The body starts
with a block table and is followed by one zlib stream per block. Each stream
decompresses to raw little-endian RGB565.

```
0x000  u32  0x58881688          magic
0x004  u32  body size           everything after the header
0x008  char[32] "LOGO"          zero padded
0x028  0xff ...                 to 0x200
0x200  u32  block count
0x204  u32  body size           repeated
0x208  u32[count] block offsets relative to the body start
       zlib streams, one per block, each RGB565 480 pixels wide
```

`LogoImage.parse` refuses a truncated image, a bad magic, a zero or oversized
block count, a table that disagrees with the body size, and overlapping
blocks. `encode` fails if the result exceeds `logo_size`, which is `0x300000`.

Block 0 is the power-on logo. Blocks 1 to 3 are the charger screens and blocks
4 onward are battery-meter strips; that firmware has no source here, so the
build keeps a stock image as a template and replaces only block 0, leaving
every other block byte-identical. `--bare` emits a single-block image instead.

The template is `platform/firmware/stock/logo.bin`, vendor firmware carried
through Git LFS, so a fresh clone needs `git lfs pull` before the packer finds
it. `--template FILE` points at a different one, and distribution packaging
passes `--bare` when the stock file is absent. Black is encoded as `0x0000`;
`--near-black` encodes it as `0x0841` for display paths that treat `0x0000` as
a transparent colour key.

## Rendering and packing

`toolbox dev os splash assets` renders every asset from the SVG. It runs
`rsvg-convert` in the toolchain container at 800 pixels high, crops the result
to its opaque bounds, and scales the swirl to 200 pixels tall with a Lanczos
filter, leaving an 80 pixel margin above and below. It writes:

| File | Content |
| --- | --- |
| `platform/splash/assets/boot-logo.png` | The swirl centred on a 480x360 black field. |
| `platform/splash/plymouth/tempo/logo.png` | The swirl alone, with alpha. |
| `platform/splash/plymouth/tempo/dot.png` | A 10 pixel white disc for the ring. |
| `platform/splash/plymouth/tempo/bar.png` | One 8x8 white square, scaled at runtime into the update bar. |
| `packages/tempo_core/assets/swirl.png` | The same field as `boot-logo.png`, for the app's home screen. |

`toolbox dev os splash build` decodes the PNG, resizes it to 480x360, packs
each pixel to RGB565 and compresses the block with zlib at level 9. It parses
the template, replaces block `--index`, block 0 by default, encodes the image
and writes `build/os/splash/logo.bin`. Distribution packaging copies that file to
`build/dist/images/logo.img` and into the SP Flash Tool folder.

```
toolbox dev os splash assets
toolbox dev os splash build [PNG] [--bare] [--near-black] [-t TEMPLATE] [-i INDEX] [-o OUTPUT]
toolbox dev os splash info IMAGE
toolbox dev os splash extract IMAGE DIRECTORY
```

`info` lists each block's packed and raw size. `extract` writes every block
that is a whole number of 480-pixel rows as a PNG and anything else as `.bin`.

## Flashing

`toolbox dev device flash-logo [IMAGE] [--scan] [--dry-run]` writes the image
from the running device over the USB link, defaulting to
`build/dist/images/logo.img` or `build/os/splash/logo.bin`. It validates the
file first: at least 520 bytes, no larger than `logo_size`, the magic and the
`LOGO` name in place, and the body size matching the file length.

The live partition is found by header scan rather than by address, because the
vendor scatter and the live layout differ. `locateLogo` streams the first
`logo_scan_size` bytes of `/dev/mmcblk0`, which is 192 MiB, and looks for
the magic followed by `LOGO` at offset 8. Exactly one hit is required; zero or
several refuse the write as ambiguous. The hit must be 4096-byte aligned, its
body must fit inside `logo_size`, its block count must be between 1 and 255,
and the repeated body size must agree with the header. `--scan` stops here and
reports the offset.

Before writing, the existing image is read back, checked for the magic and
saved under `build/toolbox/device/backups/`; an existing backup is never
overwritten. The upload is checksummed on the device before `dd` writes it at
the located offset with `conv=fsync`. `--dry-run` stops after the checksum.

Toolbox's raw installation offers the same guarded write through
`installRaw`, which always saves a safety backup. Firmware bundles place
`logo.img` at the `splash` range of the Tempo layout described in
[Boot and flashing](boot-and-flashing.md).

## The plymouth theme

`platform/splash/plymouth/tempo/` is a `script` plugin theme. The window is
black, the swirl sits centred at z=10, and it breathes between 0.9 and 1.0
opacity at 0.25 Hz, starting at full opacity so plymouth's first frame is the
frame LK left behind. Sixteen dot sprites orbit on a 132 pixel ring, which
clears the panel edge by 48 pixels; their opacity is driven as a comet tail,
one revolution per 1.6 seconds, fading in over the first 0.6 seconds. Status
messages, bullets and a password or question prompt draw under the swirl.

Three status strings drive the script's state machine:

| Status | Effect |
| --- | --- |
| `tempo-update` | The ring spins down over 0.5 seconds and a 200x6 progress bar fades in under the swirl. |
| `tempo-update-done` | The bar is hidden and the ring fades back in. |
| `tempo-handoff` | The swirl goes to full opacity and the ring fades out over 0.5 seconds; from update mode the bar is dropped and the bare swirl lands at once. |

`plymouth system-update --progress=<0-100>` fills the bar. The initramfs uses
update mode while it writes a rootfs image. The quit callback leaves the swirl
at full opacity so the last frame plymouth draws matches the first, and a
repeated `tempo-handoff` never restarts the fade.

## Staging into the rootfs and initramfs

The rootfs build installs `plymouth` and `plymouth-themes`, copies the theme
to `/usr/share/plymouth/themes/tempo` owned by root, runs
`plymouth-set-default-theme tempo` in the chroot, and calls `stagePlymouth`
on the mounted image to produce `build/os/rootfs/plymouth-payload`. It also
masks `plymouth-quit.service`, so nothing blanks the splash before the player
takes the display.

`stagePlymouth` starts from `plymouthd`, `plymouth`, `plymouthd.conf`,
`plymouthd.defaults` and the `details.so`, `script.so` and `renderers/drm.so`
plugins, reads each ELF's interpreter and `DT_NEEDED` entries with a small
bounded reader, and follows them through `lib`, `usr/lib` and their
`*-linux-*` subdirectories until the closure is complete. It adds every file
of the theme named in `plymouthd.conf` and copies the set into the payload
with library links dereferenced, since a bare SONAME link without its target
would leave a silently broken initramfs. The same step is available as
`toolbox dev os rootfs stage-plymouth TREE OUTPUT`.

The kernel build packs the payload into the initramfs manifest, refreshing the
theme files from `platform/splash/plymouth/tempo` first so a theme edit
reaches the early splash without a rootfs rebuild. See [Kernel](kernel.md) and
[Root filesystem](rootfs.md).

Two helpers serve iteration on a running player. `toolbox dev os splash
install` uploads the theme with a checksum, replaces the installed one and
sets it as the default. `toolbox dev os splash harvest` pulls the device's
plymouth binaries, their `ldd` closure, the defaults and the theme into
`build/os/rootfs/plymouth-payload`, keeping the armhf binaries in step with
the rootfs's plymouth version.

## The early splash

`platform/rootfs/initramfs/init.in` starts plymouth as soon as the display
exists; the kernel command line carries `quiet splash
plymouth.ignore-serial-consoles`. `/init` waits up to eight seconds for
`/dev/dri/card0`, because the DRM driver binds after `/init` runs and a
`plymouthd` started earlier never finds the display. No udev runs here, and
plymouth only accepts DRM devices with an initialised udev entry carrying the
seat tags, so `/init` fabricates that one entry, then runs
`plymouthd --mode=boot` and `plymouth show-splash`, taking the panel over from
LK's still-scanning logo. `/run` moves into the new root, so the daemon
survives `switch_root` and systemd's plymouth units adopt it. Everything is a
no-op without the payload.

## The hand-off

Who owns the panel at each stage:

| Stage | Owner |
| --- | --- |
| Power-on to `/init` | LK, scanning out block 0 of `LOGO`. |
| `/init` to the app's first frame | `plymouthd`, holding the DRM master. |
| First frame onward | flutter-pi, master on its own fd. |

`tempo.service` is ordered after `plymouth-start.service` and
`tempod.service`, and `plymouth-quit.service` is masked, so flutter-pi starts
while plymouth still holds the DRM master. It renders its first frame but
cannot commit it, so the frame waits and the splash keeps animating.

`app/lib/main.dart` calls `PlymouthHandoff.armOnFirstFrame()` right after
`runApp`. The package registers a post-frame callback that invokes `handoff`
on the `flutter_pi/plymouth_handoff` method channel once the first frame has
rendered. Without the native plugin, on a desktop build or a plain flutter-pi,
the call fails quietly and the same `main` serves every target.

The plugin runs the hand-off off the platform thread. The player runs
unprivileged, and `drmSetMaster` on an fd that has never been master needs
`CAP_SYS_ADMIN`, so the privileged half lives in `tempod`. The plugin marks the
DRM fd close-on-exec, connects to the `tempod` socket named by `config.yaml`
`daemon.socket`, which the build bakes in and `TEMPOD_SOCKET` overrides, and
sends one request line, `{"op":"drm-handoff"}`, with the fd attached as
`SCM_RIGHTS` on the same `sendmsg`. Ten seconds without an answer counts as a
wedged daemon.

`tempod` performs these steps in order and then answers `{"ok":true}` or
`{"ok":false,"error":"..."}`.

1. Check that the fd is a DRM primary node: a character device with major 226
   and a minor below 64.
2. Record which framebuffer each CRTC is scanning out, through that fd.
3. If `/run/plymouth/pid` exists, run `plymouth update --status=tempo-handoff`
   and wait 600 ms, a touch past the theme's 0.5 second fade.
4. Run `plymouth deactivate` under a three second timeout. It returns once
   plymouth has dropped the master and leaves its last frame on the panel; a
   `quit` here would free the buffer and leave garbage on mtk-drm.
5. `DRM_IOCTL_SET_MASTER` on the fd, retried on `EBUSY` every 50 ms for up to
   two seconds because plymouth's drop and this set can race. Any other error
   fails at once.
6. Reply. The plugin then calls `flutterpi_request_frame` so the paused commit
   lands.
7. In the background, poll until some CRTC's framebuffer differs from the
   recording, which means the app's first commit is on the panel. Only then
   close the daemon's copy of the fd and retire plymouth with
   `plymouth quit --retain-splash` until `plymouthd` is gone. Quitting earlier
   would blank the panel, because plymouth's framebuffer teardown disables the
   plane. After ten seconds without a change it quits anyway and logs that.

DRM master belongs to the open file description, which the frontend and the
daemon share, so closing the daemon's duplicate changes nothing for the
frontend, while holding it would keep a crashed frontend's master alive and
give its restart `EBUSY`. `SET_MASTER` on the current master succeeds, so a
restarted frontend may ask again. When no daemon answers, the plugin falls
back to the same sequence in process, which works whenever flutter-pi happens
to run as root; unprivileged and without `tempod` it leaves the splash up.

`tempo_core` bundles the same field as `assets/swirl.png` and uses it as the
wallpaper whenever the profile has none of its own, so on a fresh device the
frame that replaces the splash is the picture already on the panel. A user
wallpaper replaces it from the first frame onward.
