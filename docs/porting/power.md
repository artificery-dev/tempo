# Power Management

The Y2 pairs the MT6582 with a MediaTek MT6323 PMIC, and everything
electrical the software can influence goes through that chip: the charger,
the battery voltage, the backlight current sinks, the power key, the RTC and
the final power cut. Tempo drives it with the mainline `mt6397` MFD stack plus
two small regmap drivers of its own, and leaves the CPU cores always on. This
page follows the path from the PMIC registers up to the battery gauge and the
power dialog.

## Components

| Where | What |
| --- | --- |
| `platform/kernel/linux/arch/arm/boot/dts/mediatek/mt6582-innioasis-y2.dts` | The `pwrap` node, the `mt6323` MFD with its regulators, RTC, power controller and keys, the backlight and charger children, the `spm` node. |
| `platform/kernel/linux/drivers/soc/mediatek/mtk-pmic-wrap.c` | The `mediatek,mt6582-pwrap` variant and the optional wrapper interrupt. |
| `platform/kernel/linux/drivers/power/supply/mt6323-charger.c`, `mt6323-charge-policy.h` | The charger, its maintenance worker and two power supplies; the recovery current policy in a host-testable header. |
| `platform/kernel/linux/drivers/video/backlight/mt6323-backlight.c`, `drivers/input/keyboard/mtk-pmic-keys.c` | The four ISINK channels as one backlight device; the power key, guarded for PMICs without a home key. |
| `platform/kernel/linux/drivers/soc/mediatek/mt6582-spm.c`, `arch/arm/mach-mediatek/platsmp.c` | The system power manager running the vendor normal-mode program; the SRAMROM layout for secondary core release. |
| `platform/kernel/config/y2.config` | The PMIC, charger, backlight, regulator, RTC and power-off options, and the disabled CPU power management. |
| `daemon/native/src/metrics.rs`, `power.rs`, `screen.rs`, `settings.rs`; `daemon/lib/src/services/device_monitor.dart` | The sampler, the `reboot`, `poweroff` and `screen` ops, the baked-in defaults; `DeviceMonitor` behind `/api/v1/device`. |
| `packages/tempo_core/lib/src/services/readings.dart`, `device_services.dart`, `battery_gauge.dart`, `power.dart` | `BatteryReading`, the `DeviceBattery` poller, the painted gauge and `PowerDialog`. |
| `platform/rootfs/overlay/etc/systemd/logind.conf.d/10-tempo-power.conf` | logind leaves the power key to the UI. |
| `platform/recovery/build.sh`, `test-charge-policy.c` | The recovery kernel's `recovery_1a` command line and the policy test. |

## The PMIC wrapper

The MT6323 is not memory mapped; the SoC reaches it through the PMIC wrapper
at `0x1000d000`, which serialises register access over a dedicated link. The
fork adds `mediatek,mt6582-pwrap` to `mtk-pmic-wrap.c` as a variant of the
MT2701 entry: the same registers and MT6323 clock initialisation, arbitration
mask `0x3f`, DCM enabled, no bridge and no reset capability. LK has already
initialised the wrapper, so the driver re-runs the idempotent init sequence.

The wrapper interrupt is left out on purpose. It only reports starvation and
request exceptions, and on this SoC the line comes up asserted because
nothing has reset the block since LK. The variant enables no interrupt
sources, probe uses `platform_get_irq_optional`, and the board node has no
`interrupts` property, so the GIC line stays masked.

Three children hang off the wrapper. The `mediatek,mt6323` node is the
mainline MFD; its interrupt is the PMIC's dedicated EINT 25 on the GPIO
controller, level high, not the wrapper's line. The MFD spawns the RTC,
regulator, LED, keys and power-controller cells, and only the cells whose
driver is configured bind. `mt6323-backlight` and `mt6323-charger` are
siblings of the MFD rather than cells of it: each takes the wrapper's regmap
with `dev_get_regmap` on its parent. The wrapper polls with a jiffies-based
timeout, which is one reason `y2.config` selects `CONFIG_HZ_1000`.

## Regulators

`mediatek,mt6323-regulator` is the mainline driver. Only rails a consumer
names in the device tree get constraints; every other rail stays as LK left it.

| Rail | Voltage | Consumer |
| --- | --- | --- |
| `vgp2` | 1.8 V | The CS43131 DAC's VA, VP and VCP supplies. LK leaves it off, and the DAC browns out without it. |
| `vcn18` | 1.8 V | CONSYS digital core. |
| `vcn28` | 2.8 V | CONSYS RF and crystal. |
| `vcn33_bt`, `vcn33_wifi` | 3.3 V | The Bluetooth and WiFi power amplifiers. The LDO defaults to 3.6 V. |
| `vibr` | 1.8 V to 3.3 V | The vibration motor through `regulator-haptic`. |

Fixed regulators stand in for rails nobody switches: `reg_vmmc` is an
always-on 3.3 V supply that gives both MMC hosts a valid voltage window, and
three GPIO-backed nodes reproduce the DAC's enable sequence for
[Audio](audio.md).

## The charger

`mt6323-charger.c` programs the PMIC's hardware constant-current,
constant-voltage loop and then lets it run. Probe sets the limits once and
enables the path.

| Setting | Value |
| --- | --- |
| Input over-voltage | 7 V |
| Battery over-voltage | 4.3 V |
| Constant-voltage target | 4.2 V |
| Charge current code | `0xc`, about 450 mA |
| Charger watchdog | 4 s, kept armed |

Initialisation also leaves USB download mode, resets BC1.1 charger-port
detection, and enables battery-presence detection, CSDAC mode and
under-low-current detection. Enabling the loop arms the current-source DAC
soft start before `CS_EN`, `HWCV_EN`, `VBAT_CV_EN`, `CSDAC_EN` and `CHR_EN`;
without the stepping the state machine drops `CHR_EN` within a second.

The state machine can also latch the path off minutes into a charge, and
clearing the watchdog enable does not stop the watchdog. A delayed work item
runs every two seconds: it kicks the watchdog, reads the battery voltage, and
if a charger is present, `CHR_EN` has dropped and the battery is below
4.15 V, re-enables the path. An ADC error is never treated as an empty battery.

Two supplies are registered. `mt6323-charger`, of type mains, reports
`online` from the charger-detect status bit and `constant_charge_current_max`
as the programmed limit, 450 mA or 1 A. `mt6323-battery` reports `present`,
`voltage_now`, `capacity` and `status`: discharging with no charger, full at
or above 4.15 V, charging while `CHR_EN` is set, not charging otherwise.

### The recovery current policy

The module parameter `mt6323_charger.recovery_1a` is off by default, so a
normal boot charges at 450 mA under the forced command line in `y2.config`.
`platform/recovery/build.sh` sets `mt6323_charger.recovery_1a=1` for the
recovery kernel. With it on, the worker re-runs the full initialisation when
the charger-detect bit rises and programs the current code from
`mt6323_recovery_current_code` on every pass: `0xc` becomes `0x6`, about
1 A, only after three consecutive healthy checks, meaning charger detected,
charge enabled, status bit 6 set, status bit 7 clear and a valid voltage
below 4.15 V, and any failed check resets the count and the current. The
header is plain C so `platform/recovery/test-charge-policy.c` exercises it on
the host. The recovery display reads `mt6323-battery/capacity` for its
status line; see [Tempo Recovery](../platform/recovery.md).

## The battery reading path

There is no coulomb counter. The driver pulses the BATSNS request bit,
channel 7 of `AUXADC_CON22`, polls `AUXADC_ADC0` for the ready flag and takes
the 15-bit sample. Microvolts are `raw * 225 / 1024 * 1000`, the vendor's
`raw * 4 * 1800 / 32768` millivolts. Capacity is a linear interpolation over
a fixed open-circuit table from 3.3 V at 0 % to 4.2 V at 100 %, so it reads
high while the charger is pulling the terminal voltage up.

From sysfs upwards:

1. `tempod-native` discovers `/sys/class/power_supply/mt6323-battery` and
   `/sys/class/backlight/mt6323-backlight`, or the first battery-type supply
   and backlight, or `TEMPOD_BATTERY_SYSFS` and `TEMPOD_BACKLIGHT_SYSFS`.
2. Its sampler reads `capacity`, `voltage_now`, `status` and the backlight
   level every `daemon.sample_interval` seconds, 30 by default, into
   `tempod.db` under `daemon.state_dir`, the unit's `StateDirectory=tempod`,
   pruning rows older than seven days. `charging` means status `Charging`.
3. The `battery` op on the control socket reads sysfs afresh rather than
   returning the last sample, so a plugged cable shows within one poll. The
   Dart `tempod` runs `DeviceMonitor` once a second on that op and publishes
   the clamped percent and `charging` with the card observations as the
   cached `/api/v1/device` snapshot.
4. In the app, `DeviceBattery` polls the same op every five seconds while
   anything listens and publishes a `BatteryReading`; an unreachable daemon
   gives a null percent.

`BatteryGauge` paints the reading: an outlined cell with five bars,
`ceil(percent / 20)` of them lit, red for one, yellow for two, green from
three up. The digits sit before the cell when `status.batteryPercent` is on;
while charging a bolt takes that slot. A null percent lights no bars.

## Backlight

The panel backlight is the MT6323's four ISINK constant-current channels in
parallel. `mt6323-backlight.c` drives all four as one backlight-class device;
the mainline LED driver would expose four LEDs and could not turn the panel
off. `max_brightness` is 186, six current steps of 31 duty values: a level
maps to step `(level - 1) / 31` and duty `(level - 1) % 31 + 1`, and step 5
is the vendor's 24 mA ceiling. Turning a channel on programs its clocks, PWM
mode, step, double current, phase delay, chop and 20 kHz dimming frequency
before enabling it; after a cold power-off the PMIC has forgotten those
settings and would otherwise flash visibly.

The frontend runs unprivileged, so the `screen` op in `screen.rs` writes the
two sysfs attributes: `brightness`, clamped to 1 through `max`, and
`bl_power`, 0 to unblank and 4 to power down. Turning off waits out the
frontend's fade, 400 ms by default and at most five seconds, and blanks under
a frame that is already black; a newer request cuts the wait short. There is
no brightness ramp: wrapper writes land tens of milliseconds apart and read
as flicker. `DeviceScreen` asks for `max` once and scales a percent onto it.

## The power key

The key is `mt6323keys` under the MFD, `KEY_POWER`, wakeup capable, reported
through `mtk-pmic-keys` from the PMIC interrupt. The MT6323 table describes a
home key the Y2 does not have, so the fork guards the long-press reset setup
against a null home-key entry. `mediatek,long-press-mode = <1>` and
`power-off-time-sec = <0>` keep the PMIC's own long-press reset armed for the
power key alone, a hardware fallback that needs no software. logind sees the
key, but `10-tempo-power.conf` sets `HandlePowerKey=ignore` and
`HandlePowerKeyLongPress=ignore`, which releases logind's grab. In
`packages/tempo_core/lib/src/app.dart` one tap puts the screen to sleep or
wakes it, two taps toggle the dock, and a hold opens `PowerDialog`; the same
hold closes it again.

## Restart and power-off

`PowerDialog` is a modal that captures the wheel entirely. Restart and Power
Off sit on a rail, the centre button performs whichever is under the box, and
Menu does nothing there, so the reflex that leaves every other screen cannot
reboot the player. Performing sends `{"op":"reboot"}` or `{"op":"poweroff"}`
over `/run/tempod/tempod.sock`, root-owned, group of the device user, mode
0660. `power.rs` runs `/usr/bin/systemctl --no-ask-password --no-block
reboot` or `poweroff`, waits up to five seconds for it to return, and
reports the failure otherwise. Nothing bypasses systemd's shutdown sequence.

The final cut is the kernel's. `CONFIG_POWER_RESET_MT6323` binds the mainline
`mt6323-pwrc` driver to the `power-controller` cell, which registers a
power-off handler that writes the RTC `BBPU` key and the write trigger;
without it the shutdown sequence hangs at its last step. The `rtc` cell binds
`rtc-mt6397`, `CONFIG_RTC_HCTOSYS` sets the system clock from it at boot, and
the power-off handler takes its RTC base from the MFD cell's resource.

## CPU power states

The cores stay on. `y2.config` disables `CONFIG_PM`, `CONFIG_SUSPEND`,
`CONFIG_CPU_FREQ` and `CONFIG_CPU_IDLE`, and the command line carries
`clk_ignore_unused` so clocks LK left running stay on. Sleep on the Y2 is the
backlight going dark, not the SoC.

`mt6582-spm.c` brings up the system power manager at `0x10006000` from
`subsys_initcall`, runs the vendor boot-time register sequence, and loads the
28-word normal-mode PCM program that services the always-on source-clock and
thermal handshakes; the wakeup mask admits only the thermal source. Suspend
and deep idle need larger PCM images and coordination with clocks, interrupts
and the UART, and are not implemented. The driver maps the SPM bank without
claiming it, because the CONSYS and MFG power-domain drivers share the
registers, and a `state` attribute dumps them.

All four Cortex-A7 cores run. LK boots CPU0 and leaves the others spinning in
the boot ROM; `platsmp.c` adds `mediatek,mt6582` to the SRAMROM table with the
MT7623 layout at `0x10202000`, the jump address at `+0x34` and the per-core
keys at `+0x38`, `+0x3c` and `+0x40`. The enable method is
`mediatek,mt6589-smp`, `mediatek.c` lists the SoC among the machine's
compatibles, and the recovery kernel boots with `maxcpus=1`.
