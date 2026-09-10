#!/bin/sh
# Run inside tempo-toolchain from the repository root.
set -eu
root=$(pwd)
out="$root/build/recovery"
kernel_source="$root/platform/kernel/linux"
mkdir -p "$out/kernel"
# Generate a fresh base configuration from source, independent of a player build.
make -C "$kernel_source" O="$out/kernel" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- multi_v7_defconfig
sed "s|@ROOT@|$root|g" "$root/platform/kernel/config/y2.config" >> "$out/kernel/.config"
cc -Wall -Wextra -Werror -I"$kernel_source/drivers/power/supply" platform/recovery/test-charge-policy.c -o "$out/test-charge-policy"
"$out/test-charge-policy"
python3 platform/recovery/render-assets.py
python3 platform/recovery/test-status.py
python3 platform/recovery/test-transfer.py
arm-linux-gnueabihf-gcc -D_FILE_OFFSET_BITS=64 -std=c11 -O2 -static -Wall -Wextra -Werror platform/recovery/transfer.c -o "$out/recovery-transfer"
arm-linux-gnueabihf-gcc -std=c11 -Os -static -Wall -Wextra -I"$out" -I/usr/include/libdrm -L/usr/lib/arm-linux-gnueabihf platform/recovery/ui.c -ldrm -lm -o "$out/recovery-ui"
cat > "$out/initramfs.list" <<MANIFEST
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /bin 0755 0 0
dir /run 0755 0 0
file /bin/busybox $root/platform/rootfs/initramfs/busybox/busybox-armv7l 0755 0 0
slink /bin/sh busybox 0777 0 0
file /init $root/platform/recovery/init 0755 0 0
file /bin/recovery-ui $out/recovery-ui 0755 0 0
file /bin/recovery-transfer $out/recovery-transfer 0755 0 0
file /bin/start-usb $root/platform/recovery/start-usb 0755 0 0
MANIFEST
"$kernel_source/scripts/config" --file "$out/kernel/.config" \
    --set-str INITRAMFS_SOURCE "$out/initramfs.list" \
    --set-str CMDLINE 'console=ttyS0,921600n8 earlycon=uart8250,mmio32,0x11002000 loglevel=8 ignore_loglevel clk_ignore_unused maxcpus=1 rdinit=/init panic=0 mt6323_charger.recovery_1a=1' \
    --enable CMDLINE_FORCE --disable CMDLINE_EXTEND --disable CMDLINE_FROM_BOOTLOADER \
    --disable USB_CDC_COMPOSITE --disable USB_ETH --enable USB_CONFIGFS --enable USB_CONFIGFS_F_FS --enable USB_CONFIGFS_ACM \
    --enable DRM --disable DRM_FBDEV_EMULATION \
    --module DRM_MEDIATEK --enable DRM_BRIDGE_CONNECTOR --enable DRM_PANEL \
    --enable DRM_MIPI_DSI --module DRM_PANEL_GC9503V --disable FRAMEBUFFER_CONSOLE \
    --disable SOUND --disable WLAN --disable BT --disable MTK_CONSYS \
    --set-str EXTRA_FIRMWARE '' --set-str EXTRA_FIRMWARE_DIR "$root/platform/firmware"
make -C "$kernel_source" O="$out/kernel" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig
# The display stack is loaded from the initramfs: whatever the resolved
# configuration left as a module is built and embedded, in load order;
# helpers the base configuration builds in need nothing. start-display
# skips modules that are not in /modules.
config="$out/kernel/.config"
modules=
for entry in DRM_KMS_HELPER:drivers/gpu/drm/drm_kms_helper \
    DRM_DISPLAY_HELPER:drivers/gpu/drm/display/drm_display_helper \
    MTK_SMI:drivers/memory/mtk-smi \
    DRM_PANEL_GC9503V:drivers/gpu/drm/panel/panel-gc9503v \
    DRM_MEDIATEK:drivers/gpu/drm/mediatek/mediatek-drm; do
    symbol=${entry%%:*}
    path=${entry#*:}
    case "$(grep "^CONFIG_$symbol=" "$config" || true)" in
        *=m) modules="$modules $path" ;;
        *=y) ;;
        *) echo "Recovery: CONFIG_$symbol is not enabled in $config" >&2; exit 1 ;;
    esac
done
# shellcheck disable=SC2086
make -C "$kernel_source" O="$out/kernel" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j12 zImage \
    $(for module in $modules; do printf '%s.ko ' "$module"; done)
printf '%s\n' 'dir /modules 0755 0 0' >> "$out/initramfs.list"
for module in $modules; do
    printf 'file /modules/%s.ko %s/kernel/%s.ko 0644 0 0\n' "${module##*/}" "$out" "$module" >> "$out/initramfs.list"
done
printf 'file /bin/start-display %s/platform/recovery/start-display 0755 0 0\n' "$root" >> "$out/initramfs.list"
make -C "$kernel_source" O="$out/kernel" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j12 zImage mediatek/mt6582-innioasis-y2.dtb
arm-linux-gnueabihf-as -o "$out/entry.o" platform/recovery/entry.S
arm-linux-gnueabihf-ld -T platform/recovery/entry.ld -o "$out/entry.elf" "$out/entry.o"
arm-linux-gnueabihf-objcopy -O binary "$out/entry.elf" "$out/entry.bin"
python3 platform/recovery/pack.py
cp "$root/platform/firmware/stock/preloader_eastaeon82_wet_kk.bin" "$out/preloader.bin"
