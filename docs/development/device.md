# Working with a device

Everything the host tooling does to a running Y2 goes over SSH on the USB
gadget link. `toolbox dev device` owns the link, the status check, the boot
and logo writers, the rootfs staging and the diagnostics; `toolbox dev app
deploy` and `toolbox dev daemon deploy` put a freshly built player and daemon
onto the device with checksums and rollback. None of these commands are part
of the firmware build, and the build never touches a device. This page
describes what each command does and what to reach for when a boot goes wrong.

## Components

| Where | What |
| --- | --- |
| `packages/tempo_build/lib/src/device.dart` | `toolbox dev device`: the transport, `status`, `reboot`, `poweroff`, `screenshot`, `flash-boot`, `flash-logo`, `install-rootfs` and the host-card variant. |
| `packages/tempo_build/lib/src/device_link.dart` | `toolbox dev device link`: host-side configuration of the gadget interface, with optional internet sharing. |
| `packages/tempo_build/lib/src/device_diagnostics.dart` | `collect-sysinfo` and the splash harvest and install operations. |
| `packages/toolbox_core/lib/live_device.dart` | `SshDeviceTransport` and `LiveDeviceOperations`: the verified writes, the app bundle deployment and the rootfs staging. |
| `packages/tempo_build/lib/src/app.dart` | `toolbox dev app deploy` and `app attach`. |
| `packages/tempo_build/lib/src/daemon_deploy.dart` | `toolbox dev daemon deploy`: bundle verification, unit and drop-in generation, staged install with rollback. |
| `app/tool/deploy.dart`, `app/tool/attach.dart`, `daemon/tool/deploy.dart`, `toolbox/tool/device.dart` | Entry points that forward to the same routes. |
| `config.yaml` `networking.usb_gadget`, `user`, `device.partitions`, `flutter.install` | The address, the account, the eMMC geometry and the install paths every device command reads. |
| `.env.example` | The `TEMPO_DEVICE_*` and `TEMPO_SSH_OPTS` overrides. |

## The link

The device side of the link is described in
[Root filesystem](../platform/rootfs.md): the Y2 presents a CDC-ECM gadget at
`networking.usb_gadget.address`, `10.42.0.1/24`, and serves DHCP on it. Every
device command connects as `user.name` to that address, without the prefix
length. `TEMPO_DEVICE_HOST` and `TEMPO_DEVICE_USER` override both;
`TEMPO_SSH_OPTS` replaces the SSH options, which otherwise set batch mode,
disable host key checking and keep no known-hosts file. Privileged steps run
through `sudo -n`, which is why `user.passwordless_sudo` defaults to true.

`toolbox dev device link up|down|reset [--share]` configures the host end on
Linux. It finds the interface bound to `cdc_ether`, `cdc_ncm` or `rndis_host`,
or takes `TEMPO_DEVICE_IFACE` when several exist. With NetworkManager running
it creates and raises a `tempo-link` connection that asks the device for a
DHCP lease and never takes a default route, falling back to a manual address
one above the device's if the lease does not arrive. Without NetworkManager it
uses `dhcpcd` or `dhclient`, then a static address. It then pings the device
for twelve seconds; if nothing answers it unbinds and rebinds the USB device
and tries again for thirty. `reset` forces that rebind first. `--share` turns
on IPv4 forwarding, adds masquerading rules with `iptables`, sets the device's
default route through the host and checks that `deb.debian.org` resolves.
`down` removes the rules, the route and the address.

```sh
toolbox dev device link up --share
toolbox dev device status
toolbox dev device ssh journalctl -u tempod.service -b
```

`status` runs a fixed set of read-only queries: hostname, uptime, kernel
release, `/proc/cmdline`, IPv4 addresses, every `tempo*`, `tempod*` and
`plymouth*` unit, and free space on `/` and `/mnt/sd`. `ssh` passes its
arguments straight to `ssh` with the same target and options, so any remote
command works. `reboot` and `poweroff` sync twice and schedule the action a
second later in the background so the SSH session closes cleanly.

## Deploying the app

`toolbox dev app build [--release]` produces `build/app/flutter_assets`, a
debug JIT bundle or, with `--release`, the same bundle plus `app.so` compiled
with the pinned engine's `gen_snapshot`, which only runs on Linux x64. See
[flutter-pi and engine pairing](../app/flutter-pi.md) for the pairing rules.

`toolbox dev app deploy [--release] [--dry-run]` sends that bundle to
`flutter.install.bundle`, `/opt/tempo/flutter_assets`. The mode must match the
bundle: a release deploy needs `app.so` present and a debug deploy needs it
absent. `--dry-run` validates the bundle and prints the plan without opening a
connection. The live deployment:

1. Packs the bundle with a SHA-256 manifest, checks that `flutter-pi` and the
   matching debug or release engine library exist at `flutter.install`, and
   takes a `.deploy-lock` directory beside the destination.
2. Uploads the archive, compares its checksum, unpacks into a staging
   directory and verifies every file with `sha256sum -c`.
3. Records whether `tempo.service` was active or a hand-started `flutter-pi`
   was running, saving the latter's command line so it can be relaunched.
4. Stops the player, moves the old bundle aside as a backup and the stage
   into place.
5. Starts `tempo.service` for a release deploy. For a debug deploy it starts
   `flutter-pi` directly with `--pixelformat` from `flutter.pixel_format`, the
   Dart VM service on `flutter.vm_service_port` listening on every address
   with auth codes disabled, and output in `/tmp/tempo.log`.
6. Waits three seconds and checks that `flutter-pi` is running, and that the
   unit is active when it was used.

Any failure after the stop restores the backup and the previous process, and
the error says whether that recovery succeeded. A success removes the backup.
`toolbox dev app attach` then runs `flutter attach --debug-url
http://<host>:41200/` from `app/`, which is the same VM service the debug
key chord in [Boot and flashing](../platform/boot-and-flashing.md) exposes.

## Deploying the daemon

`toolbox dev daemon build --target arm` writes a bundle with a manifest to
`build/os/daemon/arm/bundle`. `toolbox dev daemon deploy [--dry-run]` refuses
anything but a complete ARM bundle: the manifest must say `target: arm` and
`native: true`, every listed file must hash correctly, `bin/tempod`,
`bin/tempod-native`, `lib/libsqlite3.so` and `lib/libtempod_native.so` must be
ARM32 ELF files, and no unlisted file may be present. The units come from
`daemon/systemd/` and the drop-ins are generated from `config.yaml`:

| File | Content |
| --- | --- |
| `tempod.socket.d/10-group.conf` | `SocketGroup=` set to `user.name`. |
| `tempod.service.d/20-runtime.conf` | The `--init-credentials` pre-start and the `TEMPOD_PROFILE_HOME`, `TEMPOD_PROFILE_USER`, `TEMPOD_SD_ROOT` and `TEMPOD_SETTINGS_FILE` environment. |
| `tempo.service.d/20-daemon.conf` | `TEMPOD_API_URL` and the two credential file paths for the player. |

The socket unit's `ListenStream` must equal `daemon.socket` or the deploy
stops before connecting. On the device it takes
`/run/lock/tempo-daemon-deploy.lock`, uploads and re-hashes the archive in a
stage under `/usr/local/lib`, backs up the existing units and entrypoint,
stops `tempo.service`, `tempod.service`, `tempod-native.service` and
`tempod.socket`, moves the runtime into `/usr/local/lib/tempod`, links
`/usr/local/sbin/tempod` to it, installs the units, reloads systemd and starts
the socket and both services. It then proves the API answers by reading the
token from `/var/lib/tempod/credentials/api-token` and requesting
`/api/v1/player`, restarts `tempo.service` if it had been active, and enables
the units. A failure after the stop puts the old runtime, units and services
back. See [tempod](../app/daemon.md) for what the daemon does once running.

## Writing the boot image and logo

`toolbox dev device flash-boot [IMAGE] [--dry-run] [--force] [--no-reboot]`
writes `build/dist/images/boot.img`, or `build/os/kernel/boot.img`, at
`device.partitions.bootimg_offset` through the running kernel. It checks the
image header and size, the eMMC capacity, the header already on the device,
the transfer checksum, and reads the range back after `dd`. `flash-logo`
locates the LOGO partition by scanning, saves the current image under
`build/toolbox/device/backups/` and never reboots. The steps and the reasons
for each guard are in
[Boot and flashing](../platform/boot-and-flashing.md#writing-from-the-running-device).

## Staging a root filesystem

`toolbox dev device install-rootfs [IMAGE] [--reboot]` copies
`build/dist/images/<hostname>.ext4.gz` to the card mounted at `/mnt/sd`,
checks free space and the checksum, then creates `FORCE_REINSTALL` there. The
initramfs writes the image to `mmcblk0p1` on the next boot; `--reboot` starts
that boot. `--sd DIR` does the same to a card in a host reader, using `sudo`
when the mount is not writable, and cannot be combined with `--reboot`. The
initramfs steps are in
[Boot and flashing](../platform/boot-and-flashing.md#the-initramfs-and-first-boot).

## Logs and diagnostics

| What | Where |
| --- | --- |
| A debug-deployed player | `/tmp/tempo.log` on the device. |
| The service-run player and daemon | `journalctl -u tempo.service`, `-u tempod.service`, `-u tempod-native.service` through `device ssh`. |
| The display | `toolbox dev device screenshot [NAME]`, saved to `build/toolbox/device/screenshots/`. |
| Kernel, device tree, debugfs, buses and units | `toolbox dev device collect-sysinfo`, saved to `build/toolbox/device/sysinfo-<stamp>/`. |
| Bluetooth audio from the host side | `toolbox dev diagnostics capture-a2dp` and `analyze-tone`. |

The screenshot helper, the sysinfo capture list and the audio tools are
described in [Diagnostics](../platform/diagnostics.md). The player's own
logger is described in [Logging](../app/logging.md). `toolbox diagnose`, the
end-user command, collects a smaller read-only report over the same transport
without credentials, settings or media names.

## Recovering a bad boot

The write paths above verify what they wrote, so the usual bad boot is a
kernel or rootfs that is intact but wrong. What helps depends on what still
runs:

| The device | What to use |
| --- | --- |
| Boots and answers SSH | `flash-boot` a known-good `boot.img`, or `app deploy` and `daemon deploy`, which restore the previous version themselves when the new one fails to start. |
| The kernel boots but the rootfs does not | Put `<hostname>.ext4.gz` and `FORCE_REINSTALL` on the card with `install-rootfs --sd DIR`; the initramfs in `boot.img` reinstalls the rootfs and boots it. |
| Nothing boots past LK, or the eMMC is wrong | Toolbox Backup & Restore. On a powered-off player it boots Tempo Recovery in RAM through the vendor download agent and writes without touching the preloader, so the device needs only its stock boot chain. Restore the full backup, or flash the `.y2-firmware` again with readback verification on. |
| A vendor tool is required | `build/dist/spft/` holds `Y2_MT6582_scatter.txt`, `DA.img` and the split images for SP Flash Tool in Download Only mode; `toolbox dev dist --full` adds the stock boot chain to that set. |

A read-back mismatch from `flash-boot` reports itself without rebooting: the
running kernel is what can repair the write, so flash again or restore before
restarting. Tempo Recovery, its entry through the download agent and what it
leaves untouched are described in [Tempo Recovery](../platform/recovery.md);
the Toolbox workflows in
[Backups and going back to stock](../getting-started/backup-and-restore.md)
and [Device operations](../toolbox/device-operations.md).
