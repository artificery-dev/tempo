# Root filesystem

Tempo's root filesystem is a Debian bookworm armhf image built with debootstrap
inside a rootful Podman container, then finished with an overlay of units and
configuration from the repository and the runtime pieces that other builds
produce: the player, `tempod`, `cadenced`, the Bluetooth bootstrap and the
Plymouth splash. Everything the builder writes comes from `config.yaml`, with
credentials merged in from the gitignored `config.local.yaml`. The image
reaches the device on a microSD card and is installed onto eMMC by the
initramfs that the kernel build embeds in `boot.img`.

## Components

| Where | What |
| --- | --- |
| `config.yaml` `device:`, `user:`, `shell:`, `networking:`, `firewall:`, `rootfs:` | Hostname, the unprivileged user and its groups, Oh My Zsh, the gadget and WiFi links, DNS and mDNS, the ufw policy, the Debian suite and package groups. |
| `packages/tempo_build/lib/src/rootfs.dart` | `RootfsImage` and `buildRootfs`: the build pipeline, `stage`, `shell`, `plan`, `clean` and the checkout lock. |
| `packages/tempo_build/lib/src/rootfs_container.dart` | `RootfsContainer`: runs those commands as root inside the toolchain image. |
| `packages/tempo_build/bin/rootfs_container.dart` | The entry point compiled and executed inside that container. |
| `packages/tempo_build/lib/src/system_runtime.dart` | `toolbox dev os runtime build`: cross-compiles the `tempo-system` helper and verifies it before staging. |
| `platform/rootfs/tool/*.dart` | Entry points for `os rootfs build`, `stage`, `shell`, `plan`, `clean`, `stage-plymouth`, `os initramfs build`, `render` and `os runtime build`. |
| `platform/rootfs/tool/runtime.dart`, `sd_ejector.dart`, `sd_formatter.dart` | The source of `tempo-system`. |
| `platform/rootfs/native/runtime.c` | `tempo-system.so`: the volume-key probe and the `flutter-pi` exec. |
| `platform/rootfs/overlay/` | Files copied verbatim onto the image: units, drop-ins, a udev rule, PipeWire and WirePlumber configuration, sysctl and logind settings. |
| `platform/rootfs/initramfs/init.in`, `initramfs.list`, `busybox/` | The initramfs template, its cpio manifest and the static ARM BusyBox. |
| `packages/tempo_build/lib/src/kernel.dart` | `renderInitramfs` and `buildInitramfs`. |
| `daemon/systemd/` | `tempod.socket`, `tempod-native.service` and `tempod.service`, installed as-is by staging. |

## Commands

```sh
toolbox dev os rootfs plan
toolbox dev os rootfs build
toolbox dev os rootfs stage
toolbox dev os rootfs shell [-- COMMAND...]
toolbox dev os rootfs clean
toolbox dev os runtime build
toolbox dev os initramfs render
toolbox dev os initramfs build
```

`plan` prints the resolved settings, the package count and whether a password
and SSH keys are configured, without touching an image. `build`, `stage`,
`shell` and `clean` need a Linux host with sudo and rootful Podman. Before
`build` or `stage` the host runs `os bluetooth build` and `os runtime build`,
then hands the action to the container. `TEMPO_ROOTFS_HOST=1` keeps the older
path that re-executes the CLI under `sudo` on the host and needs
`debootstrap`, `chroot`, `mkfs.ext4`, `e2fsck`, `git`, `systemctl` and
`/usr/bin/qemu-arm-static` installed locally.

`RootfsContainer` compiles `bin/rootfs_container.dart` to a native helper,
writes the merged configuration to a `0600` JSON file under
`build/rootfs-container/`, and runs `podman run --privileged --user 0:0
--userns=host` with the checkout bind-mounted at its real path using private
mount propagation, so loop mounts of the image never reach the host
namespace. The toolchain image supplies debootstrap, QEMU and the
filesystem tools; see [Toolchain container](toolchain.md). The pinned image
in the developer's store is exported and loaded into the rootful store first
when the two differ. `SUDO_UID` and `SUDO_GID` pass through so the
finished image is chowned back to the calling user.

`build`, `stage`, `shell` and `clean` take an exclusive `flock` on
`build/rootfs-container/image.lock`, outside the rootfs output so `clean`
cannot delete it. Distribution packaging takes the same lock. A second owner
fails at once with exit status 73 rather than waiting; the container and the
sudo re-exec set `TEMPO_ROOTFS_LOCK_HELD=1` so the inner invocation does not
lock again.

## Build pipeline

`buildRootfs` refuses to start unless `config.local.yaml` provides
`user.password` or `user.ssh_keys`. A plaintext password is hashed with
`openssl passwd -6`; a value that already looks like a crypt hash is kept.
The build then proceeds in this order.

1. Create a sparse file of `rootfs.size_mb` mebibytes at
   `build/os/rootfs/<hostname>.ext4`, format it as ext4 labelled
   `rootfs.label` with `metadata_csum_seed` off, and loop-mount it at
   `build/os/rootfs/mnt`.
2. Run `debootstrap --foreign --variant=minbase` for `rootfs.suite` from
   `rootfs.mirror`, including the `bootstrap` package group.
3. Write `/usr/sbin/policy-rc.d` returning 101 so package configuration never
   starts a daemon on the build host, mount `proc` and `devpts`, copy
   `qemu-arm-static` into the tree and run the second stage under emulation.
   The second stage removes the policy file and the mounts, so both are put
   back.
4. Write `/etc/hostname`, `/etc/hosts`, `/etc/localtime`, `/etc/timezone`, an
   `/etc/fstab` with only `proc`, and a temporary `resolv.conf`.
5. `apt-get update`, then one `apt-get install --no-install-recommends` of the
   `system`, `graphics`, `audio`, `bluetooth` and `tools` groups.
6. Generate `rootfs.locale` and set it as `LANG`.
7. Create the user, groups, credentials, sudo rule, sshd settings and consoles.
8. Write the networkd, wpa_supplicant and resolved configuration, enable or
   disable avahi, and pin mDNS in `nsswitch.conf`.
9. Stage the ufw rules inside the chroot.
10. Install Oh My Zsh, the Plymouth theme and the overlay, and enable the
    overlay's units.
11. Run the same runtime staging that `stage` performs on its own.
12. Clean apt caches and lists, remove `qemu-arm-static` and `policy-rc.d`,
    link `/etc/resolv.conf` to resolved's stub, empty `/etc/machine-id` and
    link `/var/lib/dbus/machine-id` to it.
13. Unmount, run `e2fsck -pf` and chown the output to the calling user.

Every chroot command runs with `DEBIAN_FRONTEND=noninteractive` and a C.UTF-8
locale.

### Package groups

| Group | Installed | Contents |
| --- | --- | --- |
| `bootstrap` | by debootstrap | systemd-sysv, udev, kmod, iproute2, iputils-ping, passwd, login, util-linux, systemd-timesyncd, tzdata, e2fsprogs. |
| `system` | second stage | exfatprogs, fdisk, dbus, libpam-systemd, dbus-user-session, systemd-resolved, wpasupplicant, iw, OpenSSH server and client, sudo, locales, plymouth and its themes, ca-certificates, gnupg, avahi-daemon, avahi-utils, libnss-mdns, ufw, iptables. |
| `graphics` | second stage | Mesa with lima for the Mali-400, EGL and GLES, mesa-utils, libinput and libxkbcommon for flutter-pi. |
| `audio` | second stage | PipeWire with its ALSA and PulseAudio shims, WirePlumber, alsa-utils, libmpv2, the GStreamer base, good, bad, libav, gl and pulseaudio plugin sets. |
| `bluetooth` | second stage | bluez, libspa-0.2-bluetooth, bluez-tools. |
| `tools` | second stage | Shell conveniences: zsh, git, curl, wget, editors, htop, tmux, rsync, jq, sqlite3 and similar. |

`systemd-resolved` sits in the second stage because debootstrap cannot resolve
its virtual `default-dbus-system-bus` dependency.

## Users and access

The account comes from `user:` through `useradd -m` with the configured uid,
gid, gecos and shell. The `video`, `render` and `input` groups must exist or
the build fails, since the player needs them for DRM, the GPU and the wheel;
every other listed group is added when present and reported when not. With
`user.sudoer` the account joins `sudo`, and with `user.passwordless_sudo` the
builder writes `/etc/sudoers.d/10-tempo` at mode `0440` and checks it with
`visudo -c`. The password hash is applied through `chpasswd -e` over stdin so
it never appears in a process listing; with no password the account is locked
and only keys work. Root's password is always locked.

SSH keys land in `~/.ssh/authorized_keys` with `0700` and `0600` modes.
`/etc/ssh/sshd_config.d/10-tempo.conf` sets `PermitRootLogin` from
`rootfs.permit_root_login` and enables password authentication. The build
deletes every `ssh_host_*` key the openssh-server package generated so images
flashed to different devices never share a host identity;
`tempo-ssh-hostkeys.service` regenerates them on the device.

Two consoles autologin the configured user and never root: `getty@tty1`, which
`tempo.service` conflicts with once the player is present, and
`serial-getty@ttyGS0` on the USB serial gadget, with its start limit removed
so host reconnects cannot leave it failed. Oh My Zsh is cloned once into
`build/os/rootfs/.omz-cache` and copied separately into the user's home and
root's home with a generated `.zshrc` carrying the configured theme and
plugins.

## Networking

`systemd-networkd`, `systemd-resolved` and `systemd-timesyncd` are enabled and
`systemd-networkd-wait-online` is masked so boot never waits for a link.

| File | Contents |
| --- | --- |
| `/etc/systemd/network/10-usb0.network` | The CDC-ECM gadget: the static `networking.usb_gadget.address`, which is `10.42.0.1/24`, and `DHCPServer=yes`, so a host on the cable gets a lease and can `ssh` to `10.42.0.1` with no setup. |
| `/etc/systemd/network/25-wlan0.network` | DHCPv4 and IPv6 router advertisements on the WiFi interface, route metric 50. |
| `/etc/wpa_supplicant/wpa_supplicant-nl80211-wlan0.conf` | Control socket in `/run/wpa_supplicant` owned by group `netdev`, `update_config=1`, mode `0600`. |
| `/etc/systemd/resolved.conf.d/10-tempo.conf` | `DNS=` from `networking.dns` and `MulticastDNS=no`. |

`wpa_supplicant-nl80211@wlan0.service` is enabled, and the settings UI drives
it through `wpa_cli` because the user is in `netdev`. WiFi power comes from
`mt6582-wifi-power.service` in the overlay, which writes `1` to `/dev/wmtWifi`
before wpa_supplicant starts and `0` on stop. It only runs when that node
exists, and a drop-in makes it require `tempo-modem-bootstrap.service`; see
[Radio initialization](radio-initialization.md).

Multicast DNS belongs to avahi rather than resolved because both would bind
UDP 5353. With `networking.mdns.enabled` the build enables `avahi-daemon` and
rewrites the `hosts:` line of `nsswitch.conf` to `files mdns4_minimal
[NOTFOUND=return]` followed by the remaining sources, failing if that line
cannot be produced. `.local` names go to avahi and everything else falls
through to resolved's stub listener, which `/etc/resolv.conf` links to.

The overlay's `sysctl.d/10-tempo-ping.conf` opens `net.ipv4.ping_group_range`
to every group, so `ping` works for the user through datagram ICMP sockets
without the file capability the kernel cannot read from the image.

## Firewall

With `firewall.enabled` the build runs `ufw` inside the chroot. The `iptables`
and `ip6tables` alternatives are switched to the legacy backend for the
duration so the commands succeed under emulation, and the rules are only
staged, never activated, so the host's own firewall is never touched. The
policy is `firewall.default_incoming`, which is `deny`,
`firewall.default_outgoing`, which is `allow`, `allow in on` each interface in
`firewall.trusted_interfaces`, which names `usb0`, and `ufw allow` for each
entry of `firewall.allow`, which is empty. `ENABLED=yes` goes into
`/etc/ufw/ufw.conf`, `ufw.service` is enabled, and the build refuses to
finish unless `/etc/ufw/user.rules` contains an accept rule for every trusted
interface, so a deny policy can never ship without the gadget exemption.

The overlay adds `ufw.service.d/10-tempo-needs-netfilter.conf`, a
`ConditionPathIsDirectory=/proc/net/netfilter` that makes the unit skip
cleanly on a kernel without netfilter instead of failing every boot; see
[Kernel](kernel.md).

## Overlay units

`stageOverlay` copies `platform/rootfs/overlay` onto the image, chowns every
entry to root and normalises modes to `0755` for directories and executables
and `0644` for other files, so a private checkout's umask cannot make `/etc`
unreadable.

| Unit | What it does |
| --- | --- |
| `tempo.service` | The player. Ordered after `plymouth-start.service`, `systemd-user-sessions.service` and `tempod.service`, which it requires; conflicts with `getty@tty1`; starts only when `/usr/local/bin/flutter-pi` and `/opt/tempo/flutter_assets` exist. `ExecStart` is `tempo-system launch`, `Restart=always` after one second, `OOMScoreAdjust=-600`, `TEMPO_VIDEO_SIZE=480x360`. |
| `tempo-sdmount.service` | Mounts the card at `/mnt/sd` through `tempo-system sdmount`. `BindsTo=dev-mmcblk1p1.device`, wanted by the udev rule `99-tempo-sd-automount.rules` on every add event of `mmcblk1p1`, including coldplug at boot. `ExecStop` is a lazy `umount -l` for surprise removal. |
| `tempo-ssh-hostkeys.service` | `ssh-keygen -A` before `ssh.service`, conditioned on no `ssh_host_*_key` existing. |
| `tempo-clear-reinstall-flag.service` | After `tempo-sdmount` and `local-fs.target`, runs `tempo-system clear-reinstall-flag` and touches `/var/lib/tempo-reinstall-cleared` on success; the condition on that marker makes it a one-shot. |
| `mt6582-wifi-power.service` | WMT WiFi power, described above. |
| `bluetooth.service.d/10-calibration.conf`, `mt6582-wifi-power.service.d/10-calibration.conf` | `Requires=` and `After=tempo-modem-bootstrap.service`. |
| `ufw.service.d/10-tempo-needs-netfilter.conf` | The netfilter condition above. |
| `systemd-backlight@.service` | An empty unit file, which systemd treats as masked, so the stock backlight save and restore never runs against the panel. |
| `logind.conf.d/10-tempo-power.conf` | `HandlePowerKey=ignore` and `HandlePowerKeyLongPress=ignore`, leaving the power key to the UI and keeping a tap from shutting the device down. |
| `etc/default/keyboard` | A `pc105` `us` layout so flutter-pi's xkb keymap loads without errors. |

The builder also writes `tempo.service.d/10-user.conf` from `config.yaml`:
`User=` and `Group=` the configured account, `Wants=` and `After=user@<uid>.service`,
`XDG_RUNTIME_DIR=/run/user/<uid>`, `LD_PRELOAD` of the system `libsqlite3`,
`PIPEWIRE_CONFIG_NAME=client-rt.conf`, `LimitRTPRIO=95`, `LimitNICE=-19` and
`LimitMEMLOCK=4194304`. It enables `tempo`, `tempo-clear-reinstall-flag`,
`tempo-ssh-hostkeys`, `mt6582-wifi-power` and `wpa_supplicant-nl80211@wlan0`,
masks `plymouth-quit.service` so nothing blanks the splash before the player
takes the display, and creates `/mnt/sd`. The splash hand-off itself is
described in [Boot splash](splash.md).

## Audio stack placement

PipeWire and WirePlumber run in the user's own systemd instance, not as system
services. The build writes `/var/lib/systemd/linger/<user>` so `user@<uid>`
starts at boot without a login, and `libpam-systemd` with `dbus-user-session`
gives that instance `/run/user/<uid>` and a session bus. `tempo.service` is
ordered after that instance and points `XDG_RUNTIME_DIR` at it, which is
where libmpv finds the sound server. Membership of the `pipewire` group grants
the realtime limits from `/etc/security/limits.d`, and the unit's own
`LimitRTPRIO`, `LimitNICE` and `LimitMEMLOCK` let the player's audio thread
use them.

`pipewire.conf.d/20-tempo-media-quantum.conf` sets
`default.clock.min-quantum = 512` so a short notification sound cannot drag the
graph down to 128 frames while video decoding and rendering are active.
`wireplumber/bluetooth.lua.d/51-tempo-a2dp.lua` registers no HFP or HSP
roles, disables the headset backend, enables AVRCP absolute volume, and makes
every `bluez_card.*` auto-connect and default to the `a2dp-sink` profile.

## The tempo-system helper

`toolbox dev os runtime build` produces `build/os/runtime/`: `tempo-system`,
from `dart compile exe --target-os=linux --target-arch=arm` with the uid and
gid baked in as `TEMPO_UID` and `TEMPO_GID`; `tempo-system.so`, built from
`runtime.c` by the toolchain's `arm-linux-gnueabihf-gcc`; and `manifest.json`
with both SHA-256 hashes. Staging re-hashes both files and checks that each is
a 32-bit ARM ELF before installing them under `/usr/local/lib/tempo-system/`.

| Subcommand | What it does |
| --- | --- |
| `launch` | Loads `tempo-system.so` from its own directory, asks `tempo_volume_keys_held` whether both volume keys are down on any `/dev/input/event*`, and execs `flutter-pi --pixelformat RGB565 /opt/tempo/flutter_assets`. Normally that is `--release`; with both keys held it is the JIT build with the VM service on port 41200 bound to every address and auth codes disabled. |
| `sdmount` | Creates `/mnt/sd`, reads the type of `/dev/mmcblk1p1` with `blkid`, and mounts it `sync,noatime`, adding `uid`, `gid`, `fmask=0177` and `dmask=0077` for vfat and exfat. |
| `clear-reinstall-flag` | Deletes `FORCE_REINSTALL` from the card. If `/mnt/sd` is mounted it works there; otherwise it mounts `/dev/mmcblk1p1` on a temporary directory trying vfat, exfat, ext4 and ext2, and unmounts again. No card is a failure, which leaves the unit to try on a later boot. |
| `eject-sd MOUNTID` | Confirms the mount ID of `/mnt/sd` in `mountinfo`, that the card has no other mounts and that `/mnt/sd` holds nothing but the card, checks the device type is `SD`, runs `sync -f`, a normal `umount`, and then stops `tempo-sdmount.service`. Never lazy or forced. |
| `format-sd CARDID` | Requires the card's CID to match, at least 32768 sectors and no mounts outside `/mnt/sd`. Unmounts, runtime-masks and stops `tempo-sdmount`, re-checks the CID, writes a DOS label with one type-7 partition from sector 2048 through `sfdisk --wipe always`, waits for udev, checks the CID again, runs `mkfs.exfat -L TEMPO` and `fsck.exfat -n`, syncs, and always unmasks and restarts the mount unit. The eMMC is never a target. |

Eject and format share an exclusive lock on `/run/tempo-format-sd.lock`.
`tempod`'s `CardHost` is their caller; see
[Cadence integration](../app/cadence-integration.md) for the quiescing that
precedes them.

## Stage versus build

`build` produces a fresh image and ends by staging. `stage` opens the existing
`build/os/rootfs/<hostname>.ext4`, installs the current runtime into it, closes
it and runs `e2fsck`. It never touches packages, users or configuration, so
it is the fast path after rebuilding the app or the daemon. Staging verifies
every input before writing anything:

| Input | Destination on the image |
| --- | --- |
| `build/os/runtime/` | `/usr/local/lib/tempo-system/` |
| `build/os/bluetooth/` `bootstrap`, `mmio.so`, `modem_1_2g_n.img`, the unit | `/opt/tempo-modem-diag/` and `/etc/systemd/system/tempo-modem-bootstrap.service`, enabled; any `fixture/` is deleted. |
| `build/app/flutter-pi/flutter-pi` | `flutter.install.flutter_pi` |
| `build/app/engine-binaries/arm/libflutter_engine.so.{debug,release}`, `icudtl.dat` | `flutter.install.engine_dir`, `flutter.install.icudtl` |
| `build/app/flutter_assets` | `flutter.install.bundle`, replaced wholesale, with `icudtl.dat` copied inside |
| `build/os/daemon/arm/bundle` | `/usr/local/lib/tempod/`, with `/usr/local/sbin/tempod` linked to its binary |
| `build/os/cadence/arm/bundle` | `/usr/local/lib/cadenced/`, with `/usr/local/sbin/cadenced` linked to its binary |
| `daemon/systemd/*` | `/etc/systemd/system/`, then `tempod.socket`, `tempod-native.service` and `tempod.service` enabled |

The Flutter pieces are optional and reported as not staged when absent. The
daemon, Cadence, runtime and Bluetooth bundles are required, each checked
against its manifest, and a Bluetooth bundle carrying player captures is
rejected. Staging also writes three drop-ins from `config.yaml`:
`tempod.socket.d/10-group.conf` sets the socket group to the user,
`tempod.service.d/20-runtime.conf` passes the user as the credential group and
sets `TEMPOD_PROFILE_HOME`, `TEMPOD_PROFILE_USER`, `TEMPOD_SD_ROOT=/mnt/sd` and
`TEMPOD_SETTINGS_FILE`, and `tempo.service.d/20-daemon.conf` gives the player
`TEMPOD_API_URL=http://127.0.0.1:8765` and the token file paths.
`tempod.socket` holds `/run/tempod/tempod.sock` at mode `0660` so the player
can connect before the daemon is up; `daemon/README.md` covers the daemon.

`stage-plymouth TREE OUTPUT` is the step `build` runs after
`plymouth-set-default-theme tempo`: it walks the ELF dependencies of
`plymouthd`, `plymouth`, the `details`, `script` and `drm` plugins and the
configured theme, and copies that closure with links dereferenced to
`build/os/rootfs/plymouth-payload` for the initramfs.

`shell` mounts `proc`, `sysfs`, `/dev` and `/dev/pts` into the image, lends
it the host's `resolv.conf`, and runs `/bin/bash -l` or the command after `--`
under QEMU, restoring `resolv.conf` and removing the emulator afterwards.

## Initramfs

`os initramfs render` substitutes `@HOSTNAME@`, `@ROOTFS_SIZE_MB@`, `@ROOT@`
and `@INIT@` into `init.in` and `initramfs.list` and writes the results to
`build/os/initramfs/`, failing on any placeholder left over. `os initramfs
build` renders, then generates `external.list` with the `/dev`, `/proc`,
`/sys`, `/run` and `/bin` directories, the console and null nodes,
`busybox-armv7l`, `/bin/sh` and `/init`, plus every file of the Plymouth
payload when it exists, with the theme files refreshed from
`platform/splash/plymouth/tempo`. The kernel's `gen_init_cpio`, built in the
toolchain container if missing, turns that into `initramfs.cpio.gz`, which the
kernel build packs into `boot.img`; see [Kernel](kernel.md) and
[Boot and flashing](boot-and-flashing.md).

`init` runs as follows.

1. Install the BusyBox applets and mount `proc`, `sysfs`, `devtmpfs` and a
   `tmpfs` on `/run`.
2. If `plymouthd` is packed in, wait up to eight seconds for
   `/dev/dri/card0`, fabricate the udev database entry Plymouth needs for the
   card, start `plymouthd --mode=boot` and show the splash. `/run` moves into
   the new root later, so the daemon survives `switch_root` and systemd's
   Plymouth units adopt it.
3. Scan the card for `FORCE_REINSTALL`, trying `mmcblk1p1`, `mmcblk1p2` and
   the whole disk as vfat, exfat, ext4 and ext2, for up to six seconds.
4. Unless a reinstall is forced, wait up to twenty seconds for
   `/dev/mmcblk0p1` and boot it whenever it mounts as ext4 and holds
   `/etc/os-release`. Booting means enabling `serial-getty@ttyGS0` with its
   start limit lifted, installing the first-boot resize unit, moving the
   mounts into `/newroot` and exec'ing `switch_root /newroot /sbin/init`.
5. Otherwise look for `<hostname>.ext4.gz` or `<hostname>.ext4` on the card
   and write it to `/dev/mmcblk0p1` with `dd`, switching the splash into its
   update mode and reporting progress read from the writer's `fdinfo` against
   `rootfs.size_mb`. Then boot the result.
6. A forced reinstall that found no image boots the existing rootfs. With no
   rootfs at all, `init` prints the state of both block devices and drops to a
   shell.

The resize unit is `<hostname>-resize-rootfs.service`, written into the
rootfs by `init` before the first boot. It runs `resize2fs /dev/mmcblk0p1`
before `sysinit.target` and touches `/var/lib/<hostname>-resized`, so the
`rootfs.size_mb` image grows to fill its partition once and never runs again.
The initramfs detects `FORCE_REINSTALL` but never deletes it; that is
`tempo-clear-reinstall-flag.service`'s job after a successful boot, so a
reinstall interrupted halfway simply runs again.

## Outputs

| Path | Contents |
| --- | --- |
| `build/os/rootfs/<hostname>.ext4` | The image, sized by `rootfs.size_mb`. |
| `build/os/rootfs/plymouth-payload/` | The Plymouth closure for the initramfs. |
| `build/os/rootfs/.omz-cache/` | The Oh My Zsh clone reused across builds. |
| `build/os/rootfs/mnt/` | The loop mountpoint, present only while an operation holds the image. |
| `build/os/runtime/` | `tempo-system`, `tempo-system.so`, `manifest.json`. |
| `build/os/initramfs/` | `init`, `initramfs.list`, `external.list`, `initramfs.cpio.gz`. |
| `build/rootfs-container/` | The lock file and per-invocation helper directories. |
| `build/dist/images/<hostname>.ext4.gz` | Written by `toolbox dev dist` when missing or older than the image, and listed in `SHA256SUMS`. |

`toolbox dev device install-rootfs` copies the gzipped image to the device's
card, or to a host-mounted card with `--sd`, verifies its checksum and touches
`FORCE_REINSTALL` so the next boot installs it. `os rootfs clean` removes
`build/os/rootfs` entirely after unmounting anything left there.
