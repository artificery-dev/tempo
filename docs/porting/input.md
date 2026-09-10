# Input

The Y2 has a click wheel with a centre button and four buttons on its ring,
two volume keys on the side and a power key. Three different paths bring them
into Linux: the wheel controller reports its buttons as GPIO lines and its
rotation over I2C, the volume keys sit on the MT6582 keypad matrix, and the
power key is an interrupt from the MT6323 PMIC. Every one of them ends up as
an ordinary evdev key event, which flutter-pi reads through libinput and the
app interprets as wheel words: jog, select, back, media and volume. This page
describes the hardware, the drivers in the kernel fork and the userland that
consumes them.

## Components

| Where | What |
| --- | --- |
| `platform/kernel/linux/arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts` | The `pio`, `gpio-keys`, `wheel@51`, `keypad@10011000`, `mt6323keys` and `haptics` nodes. |
| `platform/kernel/linux/drivers/gpio/gpio-mt6582.c` | The GPIO block and the EINT interrupt controller. |
| `platform/kernel/linux/drivers/input/misc/apt32f-wheel.c` | Wheel rotation from the APT32F controller over I2C. |
| `platform/kernel/linux/drivers/input/keyboard/mt6582-keypad.c` | The volume keys from the keypad matrix. |
| `platform/kernel/linux/drivers/input/keyboard/mtk-pmic-keys.c` | The power key, a mainline driver with one fix for boards without a home key. |
| `platform/kernel/config/y2.config` | `GPIO_MT6582`, `EINT_MTK`, `KEYBOARD_GPIO`, `KEYBOARD_MT6582`, `INPUT_APT32F_WHEEL`, `INPUT_UINPUT` and the haptic options. |
| `platform/rootfs/overlay/etc/default/keyboard` | The xkb layout flutter-pi loads. |
| `platform/rootfs/native/runtime.c` | `tempo_volume_keys_held` and the flutter-pi exec. |
| `platform/rootfs/tool/runtime.dart` | `tempo-system launch`, which turns the chord into debug mode. |
| `packages/tempo_core/lib/src/app.dart` | Wraps the app in `ClickWheelInput`. |
| `packages/tempo_core/lib/src/wheel_settings.dart`, `settings/settings_tree.dart` | The wheel feel settings. |
| `config.yaml` `user.groups` | `input`, so the frontend reads the devices without root. |

## The controls and their pins

| Control | Path | Line | Event |
| --- | --- | --- | --- |
| Wheel rotation | APT32F over I2C0 at `0x51`, data-ready on GPIO 55 | falling edge | `KEY_UP`, `KEY_DOWN`, `KEY_PAGEUP`, `KEY_PAGEDOWN` |
| Previous | GPIO 6 | active low | `KEY_LEFT` |
| Menu | GPIO 7 | active low | `KEY_BACK` |
| Next | GPIO 9 | active low | `KEY_RIGHT` |
| Play | GPIO 10 | active low | `KEY_PLAYPAUSE` |
| Select | GPIO 54 | active low | `KEY_ENTER` |
| Volume down | keypad matrix, `KP_MEM1` bit 0 | | `KEY_VOLUMEDOWN` |
| Volume up | keypad matrix, `KP_MEM1` bit 1 | | `KEY_VOLUMEUP` |
| Power | MT6323 PMIC, interrupt on EINT 25 | level high | `KEY_POWER` |

The five ring buttons and the wheel share one controller. The APT32F drives
each button as a dedicated line that rests high and goes low on a press, so
they are plain `gpio-keys`, all marked `wakeup-source`. Rotation is a
different matter: the controller writes a frame into its register file and
pulses the data-ready line, and the kernel reads the frame back over I2C.

I2C0 is the mainline `mt6577-i2c` controller at `0x11007000` with its AP-DMA
channel at `0x11000200`, on a fixed 66 MHz clock with `clock-div` 16. The
volume keys and the power key never touch the wheel controller.

## GPIO and EINT

`gpio-mt6582.c` covers the GPIO block at `0x10005000` and the EINT block at
`0x1000b000` in one driver bound to `mediatek,mt6582-gpio`. The GPIO block is
the classic MediaTek layout: each register group covers sixteen pins at a
`0x10` stride, with `DIR` at `0x000`, `DOUT` at `0x400`, `DIN` at `0x500` and
`MODE` at `0x600`, and every writable group has set and clear aliases at `+4`
and `+8`. The driver implements direction, input, output and `to_irq`. It does
not touch pin muxing; the bootloader muxes every pin the board uses before
Linux starts.

The EINT block is register-identical to the mainline `mtk-eint` library, so
the driver reuses it for the irqchip, the domain and wakeup handling. On the
MT6582 the EINT number is the GPIO number, so the translation callbacks are
identities; there are 169 lines across six ports, the single upstream line is
`GIC_SPI 113`, and hardware debounce exists only for EINT 0 to 15. The device
tree exposes the node as both `gpio-controller` and `interrupt-controller`,
with 169 pins:

```
pio: gpio@10005000 {
	compatible = "mediatek,mt6582-gpio";
	reg = <0x10005000 0x1000>, <0x1000b000 0x1000>;
	interrupts = <GIC_SPI 113 IRQ_TYPE_LEVEL_HIGH>;
	ngpios = <169>;
};
```

The ring buttons, the wheel's data-ready line and the PMIC interrupt all hang
off this node. None of the `gpio-keys` entries sets `debounce-interval`, so
the buttons rely on the controller's own conditioning.

## The wheel driver

`apt32f-wheel.c` is an I2C client bound to `innioasis,apt32f-wheel` with a
threaded interrupt on the data-ready line. On each pulse it writes register
pointer 0 and reads nine bytes back with a repeated start, because a plain
read begins at the chip's wandering internal pointer and misses the header:

```
reg0 = 0xAA   reg1 = 0x55 (valid)   reg2 = class   reg3 = nav index   reg4 = scroll code
```

Only class 3, wheel scroll, is handled. `reg4` selects the key: 1 is
`KEY_UP`, 2 is `KEY_PAGEUP`, 3 is `KEY_DOWN` and 4 is `KEY_PAGEDOWN`. The
driver reports a press and a release for each frame, one notch of a scroll
wheel, and does no scaling or debouncing of its own. The page codes are the
controller's fast tier, and the app treats them as page jogs. The device
registers as `APT32F click-wheel` on `BUS_I2C`.

## The volume keys

The MT6582 keypad controller at `0x10011000` scans its matrix on its own once
`KP_EN` bit 0 is set, holds the debounced state in the low sixteen bits of
`KP_MEM1`, and raises `GIC_SPI 116` on every change. A pressed key clears its
bit. `mt6582-keypad.c` enables scanning, samples the initial state, and on
each interrupt reports the bits that changed against `linux,keycodes` from
the device tree, `KEY_VOLUMEDOWN` for bit 0 and `KEY_VOLUMEUP` for bit 1.
There is no acknowledge register; the read clears the condition. Debouncing
is the controller's. The device registers as `mt6582-keypad`.

## The power key

The MT6323 is an `mt6397`-family MFD child of the PMIC wrapper whose
interrupt line is EINT 25, level high. Its `mt6323keys` child uses the
mainline `mtk-pmic-keys` driver with a single `power` key mapped to
`KEY_POWER`, marked `wakeup-source`, with `mediatek,long-press-mode` 1 and
`power-off-time-sec` 0. The fork's only change guards the driver's long-press
reset setup against boards that declare no home key, which would otherwise
dereference a null register description. The device registers as
`mtk-pmic-keys`.

## Haptics

The vibration motor is also an input device. The `haptics` node uses
`regulator-haptic` over the PMIC's `VIBR` rail between 1.8 V and 3.3 V, and
`INPUT_FF_MEMLESS` exposes it as force feedback. `tempod` plays the clicks and
ticks that go with wheel words; see [Power Management](power.md) for the rail.

## From evdev to the app

flutter-pi creates a libinput context over udev on `seat0` and receives every
key from the devices above. For keyboard events it feeds the evdev code to an
xkb keymap built from `/etc/default/keyboard`; the overlay ships a `pc105`,
`us` layout there only so the loader finds all four values it insists on, as
nothing on the player is a keyboard. The Flutter side matches keys on their
physical identity, the evdev scancode's HID translation, so the console keymap
never changes what a button means:

| Evdev code | Physical key | Wheel word |
| --- | --- | --- |
| `KEY_UP`, `KEY_DOWN` | `arrowUp`, `arrowDown` | jog one detent |
| `KEY_PAGEUP`, `KEY_PAGEDOWN` | `pageUp`, `pageDown` | page jog |
| `KEY_ENTER` | `enter` | select, or select-hold |
| `KEY_BACK` | `browserBack` | back, or menu on a hold |
| `KEY_LEFT`, `KEY_RIGHT` | `arrowLeft`, `arrowRight` | previous, next |
| `KEY_PLAYPAUSE` | `mediaPlayPause` | play and pause |
| `KEY_VOLUMEUP`, `KEY_VOLUMEDOWN` | `audioVolumeUp`, `audioVolumeDown` | volume step |
| `KEY_POWER` | `power` | tap count or hold |

`ClickWheelInput` from the `tomeui_clickwheel` package sits at the root of the
app in `app.dart` and turns those keys into intents. Detents become
`JogIntent`, which walks focus or moves a `WheelList`; the centre becomes
`ActivateIntent` on release or `ActivateHoldIntent` after 600 ms; menu is
`WheelBackIntent` on release or `WheelMenuIntent` after 1500 ms; previous,
next and play are `MediaIntent` regardless of focus, with a held form at 600
ms; the volume keys are `VolumeIntent`, spoken on the way down and repeated
every 150 ms while held, because flutter-pi does not repeat a held key. The
power key is counted as taps within a 350 ms window or a hold. A press speaks
on release so a hold is never also a press. Asleep, the wheel and menu say
nothing and the centre only wakes the screen; the media buttons, the rocker
and the power key keep working.

`WheelFeel` sets how far a detent carries. The Controls setting `Wheel >
Sensitivity` binds to `WheelSettings.setFirmness`: High is one click per row,
Medium two and Low three, applied as `rowsPerDetent` of one over the count,
with the fraction carried so a firm wheel still arrives. The Acceleration
toggle beside it binds `WheelFeel.acceleration`, which decides whether the
page codes move further than a plain detent.

## The launch chord

`tempo.service` runs `tempo-system launch`, which calls
`tempo_volume_keys_held` in `runtime.c` before it starts the player. The
function opens every `/dev/input/event*` node, asks each for its current key
state with `EVIOCGKEY`, and reports true only when `KEY_VOLUMEDOWN` and
`KEY_VOLUMEUP` are both down on some device. Holding both volume keys through
boot therefore selects debug mode: flutter-pi starts without `--release`, with
the VM service on port 41200 bound to all interfaces and authentication codes
disabled, and the launcher logs that on stderr. Otherwise it starts in release
mode. Both forms pass `--pixelformat RGB565` and the assets path; see
[Display](display.md) for the format. The frontend account is in the `input`
group so this probe and libinput both work unprivileged.

`INPUT_UINPUT` is enabled so tooling can inject wheel and button events over
ssh through a virtual device, without hands on the player.
