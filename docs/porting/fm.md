# FM

The FM receiver is the MT6627-class tuner inside the MT6582's connectivity
subsystem (CONSYS), the same block that carries Bluetooth and WiFi. The kernel
fork ports MediaTek's vendor FM driver, which talks to the tuner over the STP
link and exposes `/dev/fm`. Audio does not pass through that device: the tuner
emits I2S into the AFE, which resamples it straight into the CS43131's output.
tempod owns the receiver and the audio route, and the app's FM screen drives
tempod over its socket. Nothing here works until the radios have been
initialised, see [Radio initialization](../platform/radio-initialization.md).

## Components

| Where | What |
| --- | --- |
| `platform/kernel/linux/drivers/misc/mediatek-consys/fmradio/core/` | The vendor FM core: `/dev/fm`, the ioctl table, the STP link, RDS parsing, firmware access. |
| `platform/kernel/linux/drivers/misc/mediatek-consys/fmradio/mt6627/` | The MT6627 command set, power-up sequence and the register tables. |
| `platform/kernel/linux/drivers/misc/mediatek-consys/fmradio/inc/fm_ioctl.h` | The ioctl numbers and parameter structures userspace uses. |
| `platform/kernel/linux/drivers/misc/mediatek-consys/fmradio/core/fm_patch.c` | Maps the driver's firmware paths onto `request_firmware` names. |
| `platform/kernel/linux/sound/soc/mediatek/mt6582/mt6582-afe-pcm.c` | The `FM Playback Switch` control and the AFE registers it programs. |
| `platform/firmware/mediatek/mt6582/mt6627/` | The FM DSP patch, coefficients and board tuning, built into the kernel. |
| `platform/kernel/config/y2.config` | `CONFIG_MTK_CONSYS_FM` and the `CONFIG_EXTRA_FIRMWARE` list. |
| `daemon/native/src/radio.rs` | tempod's `fm` op: ioctls, the audio carrier, the route, RDS. |
| `daemon/native/src/protocol.rs` | The `fm` request and reply shape. |
| `packages/tempo_core/lib/src/services/fm_radio.dart` | `FmRadioService`, `DeviceFmRadio` and `FmRadioSession`. |
| `packages/tempo_core/lib/src/screens/fm_radio.dart` | The tuner screen. |

## The chip on CONSYS

The device tree has no FM node. The tuner is reached through the
`mediatek,mt6582-consys` platform node and the `mediatek,mt6582-btif` link,
which the WMT and STP stack in `drivers/misc/mediatek-consys` drives; FM is
STP task index 1. The FM driver registers its own platform device named `fm`
and creates the character device from `mt_fm_init`, independent of the
device tree. Power-up asks WMT for the FM function with
`mtk_wcn_wmt_func_on(WMTDRV_TYPE_FM)`; commands go out with
`mtk_wcn_stp_send_data` on the FM task and events arrive through the STP
event callback that `fm_request_eint` registers, so there is no wired
interrupt line. The power-up sequence reads the chip's hardware version
register and accepts `0x6625` or `0x6627`.

`y2.config` enables it with `CONFIG_MTK_CONSYS_FM=y` beside the BT and WiFi
functions. The `tempod-native.service` unit requires
`tempo-modem-bootstrap.service`, so the broker that opens `/dev/fm` does not
start before the CONSYS hardware has been brought up.

## Firmware

The vendor driver names its files under `/etc/firmware/mt6627/` and
`etc/fmr/`. `fm_patch.c` keeps only the basename and looks it up with
`request_firmware` under `mediatek/mt6582/mt6627/`, so the same tables work
with the images compiled into the kernel. `CONFIG_EXTRA_FIRMWARE` lists them
with the WMT patches and WiFi RAM code, and `CONFIG_EXTRA_FIRMWARE_DIR`
points at `platform/firmware`.

| File | Use |
| --- | --- |
| `mt6627_fm_v1_patch.bin` | The DSP patch for ROM version 1, downloaded in segments at power-up. |
| `mt6627_fm_v1_coeff.bin` | The matching coefficient table. |
| `mt6627_fm_cust.cfg` | Board tuning, parsed as text after the built-in defaults. |

At power-up the driver reads the ROM version, picks the patch and coefficient
files for that version, and falls back to the highest version present. Only
version 1 ships. The tuning file sets the long and short antenna RSSI
thresholds to `-296`, the desense RSSI to `-240`, the soft-mute gain
threshold to `16421`, 50 us de-emphasis and a 26 MHz reference oscillator.

## The driver's interface

Everything goes through `/dev/fm`. Its ioctls use magic `0xf5`, and because
the vendor header declares them `_IOWR` on pointer types, the size field
encodes the pointer width: four on this 32-bit kernel. `read()` is
non-blocking and returns one `rds_t` record, or zero bytes when no RDS event
has completed since the previous read. The ones tempod uses:

| Number | Ioctl | Argument |
| --- | --- | --- |
| 0 | `FM_IOCTL_POWERUP` | `struct fm_tune_parm`: error, band, spacing, hilo, frequency. |
| 1 | `FM_IOCTL_POWERDOWN` | `int32` |
| 2 | `FM_IOCTL_TUNE` | `struct fm_tune_parm` |
| 3 | `FM_IOCTL_SEEK` | `struct fm_seek_parm`: the tune fields plus direction and threshold. |
| 7 | `FM_IOCTL_GETRSSI` | `int32`, returned. |
| 13 | `FM_IOCTL_GETMONOSTERO` | `uint16`, non-zero for stereo. |
| 18 | `FM_IOCTL_RDS_ONOFF` | `uint16` |
| 30 | `FM_IOCTL_ANA_SWITCH` | `int32`: `0` long antenna, `1` short. |

Frequencies are in units of 100 kHz, band `1` is the 87.5 to 108 MHz band,
spacing `1` is 100 kHz, and seek direction `0` is upward and `1` downward.
The driver also offers scan, soft-mute tune, volume and mute, RDS block
counts, register access and the newer pointer-carrying tune and seek
structures; tempod does not use them.

## Audio route

The tuner is a 32 kHz I2S clock provider on the CONSYS pad. Its power-up
command sequence enables the I2S transmit path, and the driver's default
audio configuration is I2S, provider mode, 32 kHz, on the CONN pad. On the
AFE side the `FM Playback Switch` control on `hw:y2cs43131` connects that
input to the output the DAC is already playing.

Enabling it programs, in order: the gain2 connection to FM and gain2's FM
mode; the 2nd I2S input as a 16-bit I2S consumer; `AFE_CONN4` and the ASRC
registers for a 32 kHz input against the 48 kHz output; a gain ramp from
zero to unity so ASRC start-up noise is not heard; then the ASRC, the
retiming bit in `AFE_DAC_CON0` and finally the I2S input enable. Disabling
ramps gain2 to zero first, waits a millisecond, and takes the path down in
reverse. The AFE stays powered through runtime PM while the switch is on.

The output must be running for this to be audible, so tempod holds a
carrier: a silent 48 kHz stereo stream with 240-frame periods written
continuously to the `default` PCM. That is the sound server, not the raw
hardware device, because PipeWire already owns the card for the click
feedback stream; opening `hw:` directly would race it. The FM samples mix
into the same O00 and O01 pair inside the AFE and reach the CS43131 without
touching PipeWire. The sound server's volume therefore does not apply to FM,
gain2 sits at unity, and `FM_IOCTL_SETVOL` is not called; the level is
whatever the DAC gives. Because the route ends at the DAC, FM audio cannot
go to a Bluetooth sink. See [Audio](audio.md).

## Antenna

`enable` sets `FM_IOCTL_ANA_SWITCH` to the long antenna before power-up. On
this board that input is the headphone cable, and there is no other antenna.
Reception needs headphones in the jack; the FM screen does not check the jack
and shows whatever signal the tuner reports.

## tempod

The native broker answers `{"op":"fm"[,"on":bool][,"frequency_khz":N][,"seek":-1|1]}`
on `/run/tempod/tempod.sock`. A request with only `op` is a query.
`frequency_khz` and `seek` cannot be combined. Frequencies must lie in
87500 to 108000 and be multiples of 100; anything else is an error. The
reply carries `available`, which is whether `/dev/fm` exists, `on`,
`frequency_khz`, and when on `rssi`, `stereo`, `program_name`, `radio_text`,
`pi` and `pty`.

Turning on opens the device, switches the antenna, powers up at the requested
or last frequency, which starts at 95.5 MHz, starts the carrier, sets the
route, and turns RDS on, treating an RDS failure as a log line. Any failure
after power-up powers the tuner down again. Tune and seek go straight to the
ioctls, clear the decoded station, wait 60 ms and read RSSI and stereo. Every
query refreshes the signal and drains one RDS record: program name from the
PS block, radio text up to 64 bytes from the RT block, PI and PTY. Turning
off drops the route, stops the carrier and powers down, and dropping the
`Radio` value does the same. The Dart `RadioHost` and its `--radios`
endpoint handle WiFi and Bluetooth only; FM never goes through it.

## The app

`DeviceFmRadio` implements `FmRadioService` over tempod. Power, tune and
seek are immediate requests; while a screen listens it also polls once a
second so newly decoded RDS appears. Errors stay in the reading for the
screen to show as `ERROR` rather than escaping into the UI. `FmRadioSwitch`
is the same service as plain state, for tests and the emulator.

`FmRadioSession` owns the dial. It remembers the frequency and the favourites
in applet memory, and it is what Home's Now Playing page shows, so the Apps
entry can hand the receiver to Home without turning it off. Wheel input moves
the frequency one step, or five when paging, and wraps at the band edges;
the tune is sent after a 120 ms settle. Holding previous or next seeks,
tapping them jumps between favourites, and select toggles the current
frequency as a favourite. The session publishes `Playback.state` as playing
or paused while it is active. `FmRadioSession.stopActive()` powers the
receiver off: the Music and Video screens call it before taking the audio
path, holding Play calls it while the radio is active, and closing the FM
entry in the dock calls it before the entry goes.

The screen shows the frequency on an analogue band with favourites marked,
the status line `ON AIR`, `TUNING…`, `SEEKING…`, `PAUSED` or `ERROR`, the RSSI
in dBm, `Stereo` or `Mono`, and the program name and radio text once decoded.
