# Boot splash

One picture, two places: the Debian swirl on a black field, 480x360 (the Y2's
panel size, see `platform/kernel/linux/arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts`).

- **LK power-on logo** — `assets/boot-logo.png`, packed by `tool/build.dart`
  into the MTK image the `LOGO` partition holds.
- **plymouth** — `plymouth/tempo/`, which redraws the _same_ swirl at the
  _same_ size and position, then fades in a ring of dots that orbits it.

Because the geometry is shared, handing over from LK to plymouth doesn't move
the logo; only the throbber appears.

```
assets/openlogo-nd.svg      upstream Debian Open Use Logo (see the .LICENSE beside it)
assets/boot-logo.png        480x360 RGB, the flashable picture
tool/assets.dart           svg -> boot-logo.png, plymouth/tempo/{logo,dot,bar}.png
tool/build.dart             boot-logo.png -> the LOGO partition image
plymouth/tempo/         the theme
tool/install.dart       push the theme to a running device over the USB link
tool/harvest.dart             pull the device's plymouth runtime for the initramfs
```

## Recipes

```
toolbox dev os splash assets                    # re-render every asset from the SVG
toolbox dev os splash build                     # -> build/os/splash/logo.bin
toolbox dev os splash info build/os/splash/logo.bin
toolbox dev os splash extract <logo.bin> <dir>
toolbox dev os splash install                   # theme -> running device
toolbox dev os splash harvest                   # device plymouth -> build/os/rootfs/plymouth-payload
```

Sizing lives at the top of `tool/assets.dart`: `LOGO_H = 200` gives an 80px
margin above and below the swirl, and the plymouth ring at `RING_RADIUS = 132`
clears the panel edges by 48px.

## The LOGO partition

The partition holds a standard MTK bootloader image: a 512-byte header
(`0x58881688`, body size, `"LOGO"`, 0xff padding) followed by a block table and
one zlib stream per block, each of which decompresses to raw little-endian
RGB565.

Block 0 is the power-on logo. Blocks 1-3 are the charger screens and blocks 4+
are battery-meter strips — firmware we have no source for — so by default the
build takes a stock `logo.bin` as a template and swaps only block 0, leaving
every other block byte-identical. `--bare` emits a single-block image instead if
you ever want to find out what LK does without the charging assets.

### The template

`tool/build.dart` expects a stock image at
`platform/firmware/stock/logo.bin`. That is vendor firmware, carried here through Git
LFS, so a fresh clone needs `git lfs pull` before the packer will find it. To
replace it, extract one yourself from a stock or community ROM package
for the device, or
pass `--bare` to build without one.

Black is encoded as `0x0000`, matching the stock Rockbox logo. `--near-black`
encodes it as `0x0841` instead, for the display paths where `0x0000` is treated
as a transparent colour key and comes out yellow.

### Flashing

`toolbox dev device flash-logo` writes it from the running device (found by header
scan), verifies the header first, and saves the old image to `build/device/`. SP Flash Tool, with the `LOGO` row of
`Y2_MT6582_scatter.txt` pointed at `build/os/splash/logo.bin`, also works —
it resolves the partition address itself.

Use Toolbox's validated image mappings for writes. Legacy scatter addresses and
Tempo's sector-zero MBR describe different layouts; do not assume a scatter
address is an absolute raw eMMC offset.

## plymouth theme

`plymouth/tempo/` is a `script`-plugin theme:

- black window background, swirl centred at z=10, breathing 0.9..1.0 at 0.25Hz
  and starting at full opacity so the first frame matches what LK left behind
- 16 dot sprites on a 132px ring, opacity driven as a comet tail, one revolution
  per 1.6s, fading in over the first 0.6s
- status messages under the swirl, and a working password/question prompt
- an update mode: `plymouth update --status=tempo-update` spins the ring down
  and fades in a progress bar under the swirl, `plymouth system-update
  --progress=<0-100>` fills it, and `plymouth update --status=tempo-update-done`
  brings the ring back. The bar is `bar.png`, one white square, scaled to
  size. The initramfs uses it while it writes the rootfs image
  (`platform/rootfs/initramfs/init.in`); anything else that installs an update
  behind the splash can drive it the same way. A `tempo-handoff` arriving in
  update mode drops the bar and lands on the bare swirl at once.

It animates sprites rather than blitting pre-rendered frames: MT6582 has no
compositing help, so a full-screen blend at plymouth's 50Hz refresh is not
affordable, while 16 nine-pixel dots damage about 2k pixels a frame.

plymouth needs `splash` on the kernel command line (see
`platform/kernel/config/y2.config`). The theme's sprites are separate from anything
the kernel draws.

`tool/harvest.dart` pulls the plymouth runtime off a running device into
`build/os/rootfs/plymouth-payload`, which `toolbox dev os initramfs` then packs into the
initramfs so the splash starts seconds into boot, long before the rootfs.
Harvesting from the device keeps the armhf binaries in lockstep with the
rootfs's plymouth version.

One trap if you edit `tempo.script`: in plymouth's script language an
assignment inside a function creates a **local** unless the name already
resolves to a global, so `label` and `bullet` are created at top level. Building
them lazily inside the callbacks throws the sprites away as soon as the function
returns, and the text and bullets silently never appear.
