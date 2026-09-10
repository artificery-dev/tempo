# Audio

The Y2 plays through the MT6582's audio front end (AFE), a Cirrus CS43131
headphone DAC on the AFE's I2S output, and an Awinic AW87559 class-D amplifier
behind the DAC for the speaker. The kernel fork drives the three as one ASoC
card. PipeWire owns that card in the player user's session, with WirePlumber
switching between speaker, headphones and a Bluetooth A2DP sink, and the
frontend plays through libmpv as an ordinary PipeWire client. The FM receiver
has its own path into the same DAC, described in [FM](fm.md).

## Components

| Where | What |
| --- | --- |
| `platform/kernel/linux/sound/soc/mediatek/mt6582/mt6582-afe-pcm.c` | The AFE platform driver: the DL1 memory interface, the I2S output and the FM route control. |
| `platform/kernel/linux/sound/soc/mediatek/mt6582/mt6582-afe-common.h` | AFE register offsets, from the vendor `AudDrv_Afe.h`. |
| `platform/kernel/linux/sound/soc/mediatek/mt6582/mt6582-cs43131.c` | The machine driver: DAI links, the Headphone and Speaker pins, the speaker's mono mode. |
| `platform/kernel/linux/sound/soc/codecs/cs43130.c` | The mainline CS43130 driver, which covers the CS43131 and its jack detection. |
| `platform/kernel/linux/sound/soc/codecs/aw87559.c` | The amplifier codec, with the vendor register images for the AW87559 and OCA72559. |
| `platform/kernel/linux/arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts` | The `i2c1`, `afe`, `sound` and regulator nodes. |
| `platform/kernel/config/y2.config` | The `CONFIG_SND_SOC_MT6582*`, `CS43130` and `AW87559` group and the 1 kHz tick. |
| `config.yaml` | The `audio` and `bluetooth` package groups and the player user's groups. |
| `platform/rootfs/overlay/etc/pipewire/pipewire.conf.d/20-tempo-media-quantum.conf` | The minimum graph quantum. |
| `platform/rootfs/overlay/etc/wireplumber/bluetooth.lua.d/51-tempo-a2dp.lua` | A2DP-only Bluetooth policy. |
| `packages/tempo_build/lib/src/rootfs.dart` | The `tempo.service` drop-in with the realtime limits. |
| `daemon/native/src/volume.rs`, `output.rs`, `sound.rs` | tempod's `volume`, `output` and `sound` ops. |
| `packages/tempo_core/lib/src/services/playback.dart` | `MediaKitPlayback`, the player over libmpv. |
| `packages/tempo_core/lib/src/services/volume.dart`, `output.dart` | The mixer and the output as the UI sees them. |
| `packages/tempo_core/lib/src/audio_route_dialog.dart` | The "Switch to ...?" prompt when an output arrives. |
| `daemon/lib/src/services/bluetooth_player.dart` | The MPRIS player BlueZ needs for AVRCP. |

## The path

Samples leave DRAM through the AFE's DL1 memory interface, cross the AFE's
interconnect to the O00 and O01 outputs, and go out on the "2nd I2S", the one
I2S whose pads leave the chip. The CS43131 receives that I2S as the clock
consumer, converts it, and drives the headphone jack from HPOUTA and HPOUTB.
For the speaker the same two outputs feed the AW87559, whose output is the
speaker. The MT6582's own on-chip ADDA and class-D driver are not used.

| Stage | Detail |
| --- | --- |
| AFE | `0x11220000`, `GIC_SPI 104` level-low. Clocks `infra_audio`, `audintbus` and `audio` from infracfg and topckgen. No audio PLL: the block runs from the 26 MHz audio clock. |
| DL1 | One playback memif, S16_LE, one or two channels, 8 to 48 kHz. Buffer up to 256 KiB, periods from 512 bytes. |
| I2S out | `AFE_I2S_CON3`: 32-bit words, I2S framing, clock provider. 64 bit clocks per frame. |
| CS43131 | I2C1 at `0x30`. A 22.5792 MHz crystal on its XTAL pins is its MCLK; its PLL derives the 48 kHz family. Interrupt on GPIO 16, level-low. |
| AW87559 | I2C1 at `0x58`, enable on GPIO 8. Name prefix `PA`. |

The machine driver has two DAI links. `cs43131 Playback` is the dynamic front
end over the `DL1` CPU DAI. `Codec` is the back end, `I2S` to
`cs43130-asp-pcm`, format I2S with normal clocks and the codec as clock
consumer. `hw_params` hands the codec the bit clock as `rate * 32 * 2`, and
link init sets the codec's sysclk to the external crystal.

## Device tree

I2C1 is a `mediatek,mt6577-i2c` at `0x11008000` with AP-DMA channel 1 at
`0x11000280` and `GIC_SPI 45`. The DAC's five supplies are the PMIC's VGP2
for the analog rails and three GPIO-backed fixed regulators for the
power-control lines, chained so GPIO 20 rises before GPIO 18 and each waits
50 ms, as the stock driver does.

```dts
cs43131: audio-codec@30 {
	compatible = "cirrus,cs43131";
	reg = <0x30>;
	VA-supply = <&mt6323_vgp2_reg>;
	VP-supply = <&mt6323_vgp2_reg>;
	VCP-supply = <&mt6323_vgp2_reg>;
	VL-supply = <&reg_dac_15>;
	VD-supply = <&reg_dac_18>;
	interrupts-extended = <&pio 16 IRQ_TYPE_LEVEL_LOW>;
	cirrus,xtal-ibias = <2>;
};

aw87559: amplifier@58 {
	compatible = "awinic,aw87559";
	reg = <0x58>;
	enable-gpios = <&pio 8 GPIO_ACTIVE_HIGH>;
	sound-name-prefix = "PA";
};

sound {
	compatible = "mediatek,mt6582-cs43131";
	mediatek,platform = <&afe>;
	mediatek,audio-codec = <&cs43131>;
	mediatek,audio-amp = <&aw87559>;
};
```

`mediatek,audio-amp` is optional. Without it the card registers only the
headphone widget, route and switch.

## Speaker and headphones in the card

The card is named `y2-cs43131`, so ALSA calls it `hw:y2cs43131`. It exposes
two pin switches, `Headphone` and `Speaker`, and the codec driver's jack,
which appears as the `Headphone Jack` control and as an input device named
`y2-cs43131 Headphone` reporting `SW_HEADPHONE_INSERT`.

Raising the `Speaker` pin does two things. The machine driver writes the DAC's
PCM path control 2 to `0x05`, mono differential, and back to `0x00`, stereo,
when the pin drops, so the DAC is stereo whenever the speaker is off. The
amplifier's `DRV` widget then pulses its enable line low for 10 ms and high
for 100 ms and reads the chip id, `0x5a` for the AW87559 or `0x09` for the
OCA72559. It writes the register image for that chip with SYSCTRL last and
waits 80 ms. Power-down mutes SYSCTRL and drops the enable line. The card starts
with the speaker pin disabled; policy belongs to userspace.

## PipeWire

The `audio` package group installs `pipewire`, `pipewire-alsa`,
`pipewire-pulse`, `wireplumber`, `alsa-utils` and `libmpv2`. PipeWire runs in
the player user's own systemd instance, which lingers, so the frontend and
tempod both find it under that user's `XDG_RUNTIME_DIR`. WirePlumber names the
card `alsa_card.platform-sound` and its sink
`alsa_output.platform-sound.stereo-fallback`, with the routes
`analog-output-speaker` and `analog-output-headphones`; it follows the jack by
itself.

`20-tempo-media-quantum.conf` sets `default.clock.min-quantum = 512`, which
is 10.67 ms at 48 kHz, so a short notification stream cannot pull the graph
down to 128 frames while a decode and the renderer are busy. Larger client
requests are still honoured.

### Realtime

The player user is a member of `pipewire`, whose `limits.d` entry from the
package allows `rtprio 95`, `nice -19` and locked memory. The `tempo.service`
drop-in written by `rootfs.dart` gives the frontend the same room directly:

```
Environment=PIPEWIRE_CONFIG_NAME=client-rt.conf
LimitRTPRIO=95
LimitNICE=-19
LimitMEMLOCK=4194304
```

`client-rt.conf` lets libmpv's PipeWire output thread take a realtime
priority through the client's `module-rt`. Without it every audio thread is
time-shared with the UI and the library scanner, and the headphones crackle
under load. The kernel tick is 1 kHz, `CONFIG_HZ_1000`.

## The player

`MediaKitPlayback` drives libmpv through `media_kit` over `dart:ffi`, with no
video surface and no platform plugin, which is what lets it run under
flutter-pi. It sets `vid=no`, `audio-display=no`, `sub-auto=no` and
`audio-file-auto=no`, and mpv picks PipeWire as its output on its own. tempod's
click, tick and thump feedback is synthesized in `sound.rs` and written to a
48 kHz PCM kept open between sounds. Its speaker-only form opens
`pipewire:NODE=alsa_output.platform-sound.stereo-fallback,ROLE=Notification`
so feedback stays on the built-in card when Bluetooth is the default sink,
and is suppressed while the jack is occupied, since speaker and headphones
share one DAC.

## Volume

| Layer | Where | What it does |
| --- | --- | --- |
| UI | `VolumeService` | Steps of 5 percent, sent as absolute levels; one request in flight, the latest level goes next. |
| tempod | `{"op":"volume"[,"level":N][,"step":N]}` | `wpctl set-volume @DEFAULT_AUDIO_SINK@ N%` in the player user's session. |
| Reading | `output.rs` | The cached sink's linear gain from a streamed `pw-dump`, mapped by cube root to the 0 to 100 scale wpctl shows. |
| Bluetooth | `51-tempo-a2dp.lua`, `volume.dart` | AVRCP absolute volume when the transport reports a `volumeStep`; a change while paused is deferred until BlueZ says Playing and 1.5 s have passed. |

The mixer sits in the sound server, not in mpv. The FM path bypasses the
server, so this level does not apply to it; see [FM](fm.md).

## Output routing

tempod's `output` op reports where the sound goes and, with a `target`,
moves it. Its reply is `speaker`, `headphones` or `bluetooth`, the jack state
from `SW_HEADPHONE_INSERT`, the active sink's description and the Bluetooth
sinks PipeWire currently has. Selecting `speaker` or `headphones` sets the
card's `Route` with `pw-cli set-param ... { index, device, save: true }`;
selecting a Bluetooth sink by node name, or either local output, writes
`default.configured.audio.sink` with `pw-metadata`. The choice is pinned; if
the chosen sink disappears the actual fallback is pinned instead, so a
returning device cannot take the default back uninvited. `headphones` is
refused while the jack is empty.

In the app, `DeviceOutput` polls the op and publishes an `AudioOutput` of
kind speaker, headphones or bluetooth. A change of jack state or a newly
seen sink is an arrival. `TempoApp` acts on an arrival only when it crosses
between local audio and Bluetooth; speaker and headphone switching is left to
the card's own route policy. For a crossing, the `onNewDevice` setting decides:
`switch` changes at once, `ignore` does nothing, and `ask` raises
`AudioRouteDialog`, which captures the wheel to ask "Switch to X?" with Switch
and Keep Current on a rail.

For Bluetooth, `libspa-0.2-bluetooth` turns a connected A2DP device into a
sink in the same graph. The WirePlumber policy registers no HFP or HSP roles,
auto-connects `a2dp_sink`, uses the `a2dp-sink` profile and enables hardware
volume. `host_radios.dart` connects the profile over `busctl`, and
`BluetoothPlayer` publishes an MPRIS player at `/org/tempo/player` so BlueZ
has a transport to report, without which receivers acknowledge volume and do
not apply it. See [Bluetooth](bluetooth.md).

## Headphones as antenna

The FM receiver's antenna input is switched to its long-antenna position,
which on this board is the headphone cable. The player has no other antenna.
The consequences follow from the audio path above: FM audio reaches the
CS43131 inside the AFE and never enters PipeWire, so it cannot be routed to a
Bluetooth sink and does not answer the sound server's volume; it is heard on
whichever local output the jack selects. With nothing in the jack the
receiver has no antenna and the output is the speaker. The FM screen does not
gate on the jack.
