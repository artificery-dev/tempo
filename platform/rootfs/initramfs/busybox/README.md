# Static busybox for the Y2 (MT6582, armeabi-v7a)

`busybox-armv7l` — a prebuilt, statically-linked ARM binary that runs on the
stock Y2 firmware (Android 4.4.2, kernel 3.4.67). No compile needed; the
busybox.net prebuilt is compatible as-is.

- Source: https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-armv7l
- Version: BusyBox v1.31.0 (defconfig, musl, static)
- `file`: ELF 32-bit LSB executable, ARM, EABI5, statically linked, stripped
- sha256: see SHA256SUMS
- Applets: see applets.txt (396 total) — includes the tools the stock toolbox
  lacks: head, tail, od, hexdump, xxd, strings, find, tar, gzip, plus devmem
  and the full i2c set (i2cdetect/i2cget/i2cset/i2cdump).

## Deploy

```sh
adb push busybox-armv7l /data/local/tmp/busybox
adb shell chmod 755 /data/local/tmp/busybox
adb shell /data/local/tmp/busybox <applet> [args]      # e.g. busybox find /sys -iname '*gpio*'
```

`/data/local/tmp` persists across reboots (it's on userdata), so this survives
without touching /system. To make the applets callable by name, either invoke
as `busybox <applet>` or `busybox --install -s <dir>` into a writable dir on PATH.

## Verified on-device (2026-08-30)

Runs correctly; text/file applets all work. This closes the "stock toolbox is
too minimal" gap noted in references/system-info/README.md.

## What busybox does NOT fix — kernel limitations

The stock kernel blocks two Part 3 items regardless of busybox:

- **devmem (PLANNING 3.9)**: `/dev/mem` open returns ENXIO even after `mknod`,
  i.e. `CONFIG_DEVMEM` is disabled in this kernel. No raw register reads.
- **i2cdetect / live I2C scans (PLANNING 3.7)**: no `/dev/i2c-*` and no
  `/sys/class/i2c-dev`; opening a hand-mknod'd node returns ENXIO, i.e.
  `CONFIG_I2C_CHARDEV` (i2c-dev) is not built in and no i2c-dev.ko ships on
  /system (only wlan.ko is present).

Both need a kernel we control: either a small custom module (e.g. an i2c-dev
or a devmem/GPIO-dump module built against the vendor 3.4 source), or they
resolve naturally once bring-up moves to a mainline kernel. The GPIO/pinmux
dump (3.5) is blocked the same way — there is no runtime GPIO node on this
firmware, so it also depends on devmem or a custom module.
