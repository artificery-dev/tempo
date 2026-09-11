# Display

The Y2's screen is a 480x360 GalaxyCore GC9503V panel on a two-lane MIPI DSI
link, fed by the MT6582's display data path: an overlay engine, a read DMA, a
colour block and the DSI encoder, synchronised by the display mutex under
mmsys. Tempo drives the path with the mainline `mediatek-drm` driver, taught
the MT6582 register layouts, and renders through Mesa's `lima` driver on the
Mali-400 MP2. The bootloader leaves the panel scanning its logo and the kernel
takes the pipeline over at the first modeset without blanking it; the
ownership sequence at boot is in [Boot splash](../platform/splash.md).

## Components

| Where | What |
| --- | --- |
| `platform/kernel/linux/arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts` | The mmsys, OVL, RDMA, COLOR, mutex, mipi-tx, DSI, panel, GPU and MFG power nodes. |
| `platform/kernel/linux/drivers/gpu/drm/mediatek/` | `mediatek-drm`, with MT6582 compatibles and the layout differences described below. |
| `platform/kernel/linux/drivers/gpu/drm/panel/panel-gc9503v.c` | The panel driver: init sequence, mode and DSI link parameters. |
| `platform/kernel/linux/drivers/phy/mediatek/phy-mtk-mipi-dsi-mt8173.c`, `phy-mtk-mipi-dsi.c` | The D-PHY and its PLL, with the MT6582 bring-up order. |
| `platform/kernel/linux/drivers/soc/mediatek/mtk-mmsys.c`, `mtk-mutex.c` | The mmsys routing and display mutex tables for the MT6582. |
| `platform/kernel/linux/drivers/clk/mediatek/clk-mt6582-mm.c` | The mmsys clock gates the display blocks consume. |
| `platform/kernel/linux/drivers/soc/mediatek/mt6582-mfg-power.c` | The Mali power domain, a small genpd provider. |
| `platform/kernel/linux/drivers/tty/vt/vt.c` | The console palette's near-black colour 0. |
| `platform/kernel/config/y2.config` | The DRM, panel, lima, CMA and console options, and the kernel command line. |
| `config.yaml` `flutter.pixel_format`, `platform/rootfs/native/runtime.c` | `RGB565`, and the `tempo-system launch` exec that passes it to flutter-pi as `--pixelformat`. |
| `platform/recovery/start-display` | Recovery's module load, panel reset and early PHY bring-up. |
| `platform/diagnostics/device-screenshot.c` | Reads the scanout address from OVL layer 0 and copies the frame. |
| `packages/tempo_kms/` | `tempo-kms`, the Rust crate that opens the card and finds the panel, its mode and a CRTC for the native tools. |

## The panel

The panel module is a GC9503V controller in DSI video mode with sync pulses,
two data lanes and RGB888 on the link. `panel-gc9503v.c` binds to
`innioasis,y2-gc9503v` under the DSI host and advertises one mode:

```
pixel clock 27.362 MHz
horizontal  480 active, 200 front porch, 10 sync, 200 back porch, 890 total
vertical    360 active, 60 front porch, 8 sync, 60 back porch, 496 total
```

That is about 62 Hz. The file's comments discuss a 368-line active area, but
the mode table drives 360 lines, which is the size every userland consumer
assumes. The init table is forty DCS writes ending in six identical 52-byte
gamma tables, followed by exit-sleep, a 120 ms wait, display-on and 20 ms.
`prepare` starts with a reset pulse of high, 10 ms low, then 120 ms high on an
optional `reset` GPIO, and enables a `power` regulator. The Y2 device tree
gives the panel node neither, so on the player the bootloader's reset stands
and the regulator core hands the driver a dummy supply. The panel is not
linked to a backlight; brightness is the MT6323's ISINK channels through
`mt6323-backlight`, a separate class device described in
[Power Management](power.md).

## The pipeline

The display data path is a chain of engines that latch their registers on a
start-of-frame pulse from the mutex. `mtk_drm_drv.c` defines the MT6582 path
and marks it `shadow_register`:

```
OVL0 -> RDMA0 -> COLOR0 -> DSI0
```

| Block | Address | Interrupt | Driver data |
| --- | --- | --- | --- |
| mmsys | `0x14000000` | | `clk-mt6582-mm` for the gates, default routing table. |
| OVL0 | `0x14007000` | SPI 153 | mt2701 layout: address register at `0x40 + 0x20 * layer`. |
| RDMA0 | `0x14008000` | SPI 152 | mt2701 layout. |
| COLOR0 | `0x1400b000` | SPI 156 | mt2701 layout. |
| mutex | `0x1400e000` | SPI 161 | mt2701 MOD register and table, mt2712 SOF table. |
| DSI0 | `0x1400c000` | SPI 157 | mt2701 command queue offset, conservative PHY timing. |
| mipi-tx | `0x10010000` | | mt8173 register layout, MT6582 PLL sequence. |

All the display interrupts are level-low at the GIC. The `bls` block at
`0x1400a000` is declared as an mt2701 `disp-pwm` node and is not part of the
path. There is no IOMMU on the MT6582, so `mediatek-drm` allocates its GEM
objects from CMA; `y2.config` reserves 16 MB.

The mt2701-generation blocks differ from the mt8173 ones the mainline driver
was written around, and the fork records each difference where it matters:

- The OVL colour-format table is `RGB888=0, RGB565=1, ARGB8888=2,
  PARGB8888=3, xRGB8888=4`. X formats map to the hardware's own xRGB code,
  because this generation has no constant-blend bit and mapping them to ARGB
  would honour a garbage alpha byte. The format list is limited to the 8888,
  888 and 565 pairs.
- The layer address register sits where newer parts keep `PITCH_MSB`, so the
  pitch-MSB and AFBC header writes are skipped on this layout.
- `OVL_RDMA_GMC` is programmed to `0x10101010` and `RDMA_FIFO_CON` to
  `0x01000010`, the values the bootloader uses, because the mt2701-derived
  threshold maths overdrives the smaller FIFOs and corrupts the stream.
- A running OVL is never soft-reset, and `mtk_rdma_stop` follows the engine
  disable with a soft reset and waits for the FSM to report idle, because an
  engine stopped mid-frame on a shadow-register path never sees another
  start-of-frame.

## DSI and its clocks

The DSI node takes three clocks from mmsys and the PHY: `engine`, `digital`
and `hs`, the last being the mipi-tx PLL output. The driver computes the lane
rate from the mode: 27.362 MHz times 24 bits over two lanes gives 328.344
Mbit/s per lane, the same value `start-display` passes as `bringup_rate`.

The MT6582 PHY is register-compatible with the mt8173 one but needs a
different bring-up order, so `mtk_mipi_tx_pll_prepare` in the mt8173 file is
rewritten for it: bias and LDO enables first, the SDM powered with isolation
and then de-isolated, fixed dividers with `TXDIV0=1` and an integer `PCW` of
52, lane LDOs enabled before `PLL_EN`, a blind write of `PRESERVE=3` for the
divide-by-four post-divider because a read-modify-write of `PLL_TOP` stalls
the bus, and finally the pad tie-low released. The requested rate does not
change the dividers; the PLL is fixed at the panel's rate.

Register access to the DSI engine needs its clocks running, and the PLL must
be enabled after them, so `mtk_dsi_poweron` enables `engine` and `digital`
before `phy_power_on`, the reverse of mainline, and probe enables the clocks
before its first register touch. Probe also clears `INTEN` and `INTSTA`
before requesting the interrupt, because the bootloader hands the engine over
with the interrupt asserted, and power-on forces command mode so the panel's
DCS writes go out as command transfers. The `mt6582-dsi` driver data selects
a fixed set of D-PHY timings, `HS_TRAIL` and `CLK_TRAIL` of 14 among them,
because the mainline formulas end each burst so sharply that the panel
corrupts the last bytes of every line.

Module parameters exist for bring-up under Recovery, where the bootloader
has not initialised the PHY: `bringup_phy=1` powers the PHY at probe, at
`bringup_rate`, before any register access, and `start-display` loads
`mediatek-drm` that way. The `y2_fbmark` helpers in the PHY files paint the
bootloader framebuffer a solid colour; they are debugging aids with no callers.

## Reset and GPIO

The panel reset is the mmsys LCM reset signal routed to GPIO 112 in mode 1.
The bootloader configures both before Linux runs, which is why the panel node
carries no `reset-gpios`. Recovery boots from the download agent instead of
the bootloader, so `start-display` repeats the setup by hand:

```sh
devmem 0x10005768 32 0x1c0   # clear GPIO 112's three mode bits
devmem 0x10005764 32 0x40    # mode 1
devmem 0x1400013c 32 1       # LCM reset high, low 10 ms, high 120 ms
```

The two `devmem` writes use the GPIO block's clear and set aliases so that
only GPIO 112's mode field changes. The GPIO block itself is described in
[Input](input.md).

## The framebuffer and RGB565

The scanout format is RGB565. The panel driver's comments, the DRM driver's
fbdev setup and the bootloader all agree on 16 bits per pixel: the bootloader's
logo buffer at `0xbfb54600` is 480x360x2 bytes, `drm_fbdev_ttm_setup` is
called with 16, the splash packer produces RGB565, and `runtime.c` passes
`--pixelformat RGB565` so flutter-pi chooses a matching EGL configuration and
GBM surface. The DSI link itself carries RGB888; the OVL expands each pixel on
the way out. The OVL also accepts 32-bit buffers, and `recovery-ui` draws
XRGB8888 into a dumb buffer, but the player keeps every owner of the panel on
one format so the hand-offs never involve a format change.

Two consequences show up in the fork. `mtk_gem_dumb_create` maps and zeroes
dumb buffers, because the arm32 DMA path otherwise hands back uncleared CMA
pages that flash as garbage before the first draw. And `vt.c` moves console
colour 0 from `0x000000` to `0x080808`, because a pixel of exactly `0x0000`
on this panel is a transparent colour key that shows yellow. `device-screenshot.c`
relies on the same facts: it reads OVL layer 0's address register at
`0x14007040`, maps 480x360x2 bytes there through `/dev/mem` and writes them
out for the host to convert; see [Diagnostics](../platform/diagnostics.md).

## The GPU

The Mali-400 MP2 sits at `0x13010000` with the standard Utgard layout: GP,
L2, GP MMU, two PP MMUs and two PPs. Its six interrupts are SPI 170 to 175 and
must be declared level-low; declared level-high they read permanently
asserted, storm at probe, get disabled by the spurious-interrupt guard, and
lima falls back to polling each job at about five frames per second. The
node's `bus` and `core` clocks are one fixed 286 MHz clock, because the clock
source is left as the bootloader set it.

Power comes from `mt6582-mfg-power`, a genpd provider over three register
windows: the SPM at `0x10006000`, the MFG clock gate at `0x13000000` and the
display clock gate at `0x14000100`. `power_on` unlocks the SPM, ungates
`SMI_COMMON` so the GPU has a memory path, walks the MTCMOS sequence on
`MFG_PWR_CON` with `PWR_ON`, `PWR_ON_2ND`, the status acknowledgements,
`PWR_CLK_DIS`, `PWR_ISO`, `PWR_RST_B` and `SRAM_PDN`, then ungates the G3D
clock. `power_off` only regates the clock and leaves the rail up. The domain
starts off and lima's runtime PM turns it on at probe.

Userland reaches the GPU through Mesa's `lima` driver from the `graphics`
package group in `config.yaml`. flutter-pi creates its GBM device on the
`card0` file descriptor and renders with EGL and GLES, and `mediatek-drm`
scans out the buffers it presents; the frontend runs unprivileged in the
`video` and `render` groups.

## Sharing the pipeline

Three programs own the panel in turn, and the design keeps the bootloader's
scanout alive until the first real modeset.

| Owner | How it gets the panel |
| --- | --- |
| LK | Scans its logo from `0xbfb54600`, above the 992 MB the device tree gives Linux, with the pipeline free-running in video mode. |
| plymouth | Started by `/init` once `/dev/dri/card0` exists; its first modeset is the takeover. |
| flutter-pi | Starts under plymouth, renders its first frame, then `tempod` sets DRM master on its fd and retires plymouth. |

The takeover lives in `mtk_crtc_ddp_hw_init`. Before configuring anything it
calls the DSI's `quiesce` hook, which clears video mode and waits for the
engine to go idle at a frame boundary, and then stops the upstream engines in
turn, so the configuration that follows runs as on a cold boot. Stopping an
engine with a frame in flight would wedge the path instead. The hook runs
once; on later enables the DSI clocks may be gated. The kernel command line
in `y2.config` sets `drm_kms_helper.fbdev_emulation=0`, so the console never
performs that first modeset and the logo stays on screen until plymouth
draws the same picture. `mtk_drm_bind` probes every connector once at bind,
because without the fbdev client nothing else would, and plymouth skips
connectors whose status is still unknown. The hand-off between plymouth and
the player is described in [Boot splash](../platform/splash.md).

`tempo-kms` is the Rust crate the native device tools share for the same
first steps: open `/dev/dri/card0`, find the connected connector, take its
preferred mode and find a CRTC. It speaks DRM through the pure-Rust `drm`
crate and leaves buffers and presentation to each tool.
