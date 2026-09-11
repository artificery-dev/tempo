# Configuration reference

Every build and development command reads one merged configuration:
`config.yaml`, which is tracked and public, with `config.local.yaml` deep-merged
over it when that file exists. The merged values are read by key through
`BuildConfig` in `packages/tempo_build`, and a handful of them are baked into
the daemon, the embedder and the `tempo-system` helper at build time. Beside
the YAML there are two sets of environment variables: the ones the host tooling
honours, listed in `.env.example`, and the ones the player and daemon services
read on the device, listed in `.env.device.example`. This page lists every key
and every variable, its default, what it does and which code reads it.

## Components

| Where | What |
| --- | --- |
| `config.yaml` | The tracked workspace configuration; no credentials. |
| `config.local.yaml` | Gitignored overlay for the device password and SSH keys. |
| `config.local.example.yaml` | The template for the overlay. |
| `.env.example` | Host-side overrides for the build and the `toolbox dev` CLI. |
| `.env.device.example` | Service overrides the player, `tempod` and `tempod-native` read on the device. |
| `packages/tempo_build/lib/src/context.dart` | `BuildConfig.load`, `get`, `string`, `redacted` and the `user.ssh_keys` expansion. |
| `packages/tempo_build/lib/src/commands.dart` | `toolbox dev config json`, `get`, `has` and `toolbox dev secrets status`, `hash`. |
| `packages/tempo_build/lib/src/rootfs.dart` | The largest reader: `plan` prints the resolved keys, `buildRootfs` applies them. |

## How the files are read

`BuildConfig.load` in `packages/tempo_build/lib/src/context.dart` parses
`config.yaml`, then `config.local.yaml` if present, and merges them with
`deepMerge`: maps merge key by key and any scalar or list in the local file
replaces the tracked value. `get('a.b.c')` walks the merged map and returns
`null` or a fallback for a missing key; `string(key)` throws a `BuildFailure`
for a missing or non-scalar key. Keys are read by these dotted names throughout
`tempo_build`, so the citations below name the file and line that reads each
one.

```sh
toolbox dev config json                 # merged configuration, password redacted
toolbox dev config get flutter.sdk_version
toolbox dev config has user.ssh_keys    # exit 0 when present and non-empty
toolbox dev os rootfs plan              # every rootfs-relevant key, resolved
```

`.env*` files are gitignored and are never loaded by the CLI. They document
variables that must be exported in the shell that runs the command.

## `config.yaml`

### `device`

| Key | Default | Meaning | Read by |
| --- | --- | --- | --- |
| `hostname` | `tempo` | `/etc/hostname` and `/etc/hosts`, the rootfs image name `<hostname>.ext4`, `@HOSTNAME@` in the initramfs. | `rootfs.dart`, `kernel.dart`, `distribution.dart`, `device.dart` |
| `partitions.emmc_size` | `0x1d2000000` | Size of the eMMC USER area. A device whose `/dev/mmcblk0` differs is refused before any write. | `device.dart`, `distribution.dart` |
| `partitions.rootfs_offset` | `0x5180000` | Raw USER offset of the rootfs partition. Must agree with `TempoLayout`. | `distribution.dart` |
| `partitions.rootfs_size` | `0x1cce80000` | Length of the rootfs partition. | `distribution.dart` |
| `partitions.bootimg_offset` | `0x2900000` | Where LK reads the boot image on a running device; `flash-boot` writes here. | `device.dart`, `distribution.dart` |
| `partitions.bootimg_size` | `0x1000000` | Largest `boot.img` the packer and `flash-boot` accept. | `kernel.dart`, `device.dart`, `distribution.dart` |
| `partitions.logo_size` | `0x300000` | Bound on the `LOGO` image body. | `splash.dart`, `device.dart` |
| `partitions.logo_scan_size` | `0xc000000` | How far into `/dev/mmcblk0` the `LOGO` header scan looks. | `device.dart` |

All offsets are physical byte offsets into `/dev/mmcblk0`, not scatter
addresses; see [Boot and flashing](../platform/boot-and-flashing.md). The file
paths above are under `packages/tempo_build/lib/src/`.

### `user`

| Key | Default | Meaning | Read by |
| --- | --- | --- | --- |
| `name` | `tempo` | The unprivileged account the player runs as; the SSH user for `toolbox dev device`; the group of `tempod.socket`. | `rootfs.dart`, `device.dart`, `daemon_deploy.dart` |
| `uid`, `gid` | `1000`, `1000` | The account's ids. Baked into `tempo-system` as `TEMPO_UID` and `TEMPO_GID`, and into `tempod-native` as its PipeWire runtime directory default. | `rootfs.dart`, `system_runtime.dart`, `daemon.dart` |
| `gecos` | `Tempo` | The account's full name. | `rootfs.dart` |
| `shell` | `/bin/zsh` | The login shell. | `rootfs.dart` |
| `sudoer` | `true` | Adds the account to `sudo`. | `rootfs.dart` |
| `passwordless_sudo` | `true` | Writes `/etc/sudoers.d/10-tempo` with `NOPASSWD`, which the device tooling relies on. | `rootfs.dart` |
| `groups` | `video`, `render`, `input`, `audio`, `plugdev`, `dialout`, `netdev`, `pipewire` | Supplementary groups. The first three must exist or the build fails. | `rootfs.dart` |
| `password` | unset | Belongs in `config.local.yaml`; see below. | `rootfs.dart`, `bootstrap.dart` |
| `ssh_keys` | unset | Belongs in `config.local.yaml`; see below. | `context.dart`, `rootfs.dart` |

### `shell`

| Key | Default | Meaning | Read by |
| --- | --- | --- | --- |
| `setup_oh_my_zsh` | `true` | Install Oh My Zsh into the user's and root's home directories. | `rootfs.dart` |
| `oh_my_zsh_theme` | `ys` | `ZSH_THEME` in the generated `.zshrc`. | `rootfs.dart` |
| `oh_my_zsh_plugins` | `git`, `sudo`, `systemd`, `colored-man-pages`, `extract`, `safe-paste` | The `plugins=` list. | `rootfs.dart` |

### `networking`

| Key | Default | Meaning | Read by |
| --- | --- | --- | --- |
| `usb_gadget.interface` | `usb0` | The CDC-ECM gadget interface; names the networkd file and the host-side link search. | `rootfs.dart`, `device_link.dart` |
| `usb_gadget.address` | `10.42.0.1/24` | The device's static address on the gadget link. Without the suffix it is the default SSH host. | `rootfs.dart`, `device.dart`, `device_link.dart`, `app.dart` |
| `usb_gadget.dhcp_server` | `true` | `DHCPServer=yes` in the gadget's `.network` file. | `rootfs.dart` |
| `wifi.interface` | `wlan0` | Names the `25-<iface>.network` and `wpa_supplicant-nl80211-<iface>.conf` files. | `rootfs.dart` |
| `dns` | `9.9.9.9`, `1.1.1.1` | `DNS=` in `resolved.conf.d/10-tempo.conf`; the first entry is the build-time `resolv.conf`. | `rootfs.dart` |
| `mdns.enabled` | `true` | Enable `avahi-daemon` and pin `mdns4_minimal` in `nsswitch.conf`. | `rootfs.dart` |

### `firewall`

| Key | Default | Meaning | Read by |
| --- | --- | --- | --- |
| `enabled` | `true` | Stage ufw rules in the chroot and enable `ufw.service`. | `rootfs.dart` |
| `default_incoming` | `deny` | `ufw default <policy> incoming`. | `rootfs.dart` |
| `default_outgoing` | `allow` | `ufw default <policy> outgoing`. | `rootfs.dart` |
| `trusted_interfaces` | `usb0` | `ufw allow in on <iface>`; the build refuses to finish without an accept rule for each. | `rootfs.dart` |
| `allow` | empty | One `ufw allow <rule>` per entry, in ufw's own syntax such as `22/tcp`, for every other interface. | `rootfs.dart` |

### `rootfs`

| Key | Default | Meaning | Read by |
| --- | --- | --- | --- |
| `suite` | `bookworm` | The Debian release debootstrap installs. | `rootfs.dart` |
| `mirror` | `http://deb.debian.org/debian` | The debootstrap mirror. | `rootfs.dart` |
| `arch` | `armhf` | The debootstrap architecture. | `rootfs.dart` |
| `size_mb` | `4096` | Size of the sparse image; `@ROOTFS_SIZE_MB@` in the initramfs for install progress. | `rootfs.dart`, `kernel.dart` |
| `label` | `tempo-root` | The ext4 label. | `rootfs.dart` |
| `locale` | `en_US.UTF-8` | Generated and set as `LANG`. | `rootfs.dart` |
| `timezone` | `UTC` | `/etc/localtime` and `/etc/timezone`. | `rootfs.dart` |
| `permit_root_login` | `false` | `PermitRootLogin` in `sshd_config.d/10-tempo.conf`. | `rootfs.dart` |
| `packages.bootstrap` | see file | Packages passed to `debootstrap --include`. | `rootfs.dart` |
| `packages.system`, `graphics`, `audio`, `bluetooth`, `tools` | see file | Installed in one `apt-get install --no-install-recommends` in the chroot. | `rootfs.dart` |

`toolbox dev os rootfs plan` reads `rootfs.packages` as a whole to report the
package count, in `rootfs.dart`. The groups and their contents are
described in [Root filesystem](../platform/rootfs.md).

### `flutter`

| Key | Default | Meaning | Read by |
| --- | --- | --- | --- |
| `sdk_version` | `3.44.9` | The device app's Flutter SDK; `FlutterSdk.discover` looks for it under `build/sdks/flutter/`. | `context.dart`, `bootstrap_sdk.dart`, `toolbox.dart` |
| `engine_binaries.repo`, `commit` | ardera's `flutter-engine-binaries-for-arm` at a fixed commit | Where the prebuilt `libflutter_engine.so` and `gen_snapshot` come from. | `embedder.dart` |
| `flutter_pi.repo`, `commit` | ardera's `flutter-pi` at a fixed commit | The embedder source the app build compiles. | `embedder.dart` |
| `pixel_format` | `RGB565` | Passed to `flutter-pi --pixelformat` when the app is deployed over SSH. The shipped launcher in `platform/rootfs/native/runtime.c` carries the same literal. | `app.dart` |
| `install.flutter_pi` | `/usr/local/bin/flutter-pi` | Where the embedder is installed. | `rootfs.dart`, `app.dart` |
| `install.engine_dir` | `/usr/lib` | Where `libflutter_engine.so.{debug,release}` land. | `rootfs.dart`, `app.dart` |
| `install.icudtl` | `/usr/share/flutter/icudtl.dat` | Where `icudtl.dat` lands. | `rootfs.dart` |
| `install.bundle` | `/opt/tempo/flutter_assets` | The asset bundle directory. | `rootfs.dart`, `app.dart` |
| `vm_service_port` | `41200` | The Dart VM service port of the debug build; `toolbox dev app attach` connects to it. `runtime.c` carries the same literal. | `app.dart` |

The three pins move together; see
[flutter-pi and engine pairing](../app/flutter-pi.md).

### `firmware`

| Key | Default | Meaning | Read by |
| --- | --- | --- | --- |
| `version` | `0.9.0` | The public firmware version written into the `.y2-firmware` manifest. | `distribution.dart` |
| `stock_rom` | `platform/firmware/stock` | The directory `toolbox dev dist --full` takes the preloader, `MBR`, `EBR1`, `lk.bin` and `secro.img` from. The splash build uses the fixed path `platform/firmware/stock/logo.bin` for its template. | `distribution.dart` |

### `cadence`

| Key | Default | Meaning | Read by |
| --- | --- | --- | --- |
| `repository` | `https://git.artificery.dev/artificery/cadence` | The Cadence repository whose release is fetched. | `cadence.dart` |
| `release` | `v0.9.0` | The release tag of the armhf `cadenced` bundle. | `cadence.dart` |
| `bundle_sha256` | see file | The tarball checksum `toolbox dev cadence fetch` requires. | `cadence.dart` |

### `daemon`

| Key | Default | Meaning | Read by |
| --- | --- | --- | --- |
| `dart_version` | `3.13.2` | The Dart version the daemon compiler must report. | `daemon.dart`, `bootstrap_sdk.dart` |
| `toolchain_version` | `3.47.2` | The Flutter SDK that bundles that Dart. | `daemon.dart`, `bootstrap_sdk.dart`, `commands.dart`, `daemon_deploy.dart` |
| `socket` | `/run/tempod/tempod.sock` | The control socket. Baked into `tempod-native` as `TEMPOD_DEFAULT_SOCKET`, into the flutter-pi plugin as `-DTEMPOD_SOCKET`, and checked against `tempod.socket` on deploy. | `daemon.dart`, `embedder.dart`, `daemon_deploy.dart` |
| `state_dir` | `/var/lib/tempod` | The metrics database directory, baked in as `TEMPOD_DEFAULT_STATE_DIR`. | `daemon.dart` |
| `sample_interval` | `30` | Seconds between metric samples, baked in as `TEMPOD_DEFAULT_INTERVAL`. | `daemon.dart` |

`daemon/native/build.rs` turns the four `TEMPOD_DEFAULT_*` variables into
compile-time constants in `daemon/native/src/settings.rs`. `daemon/systemd/tempod.socket`
carries the socket path as a literal `ListenStream=`, which is why deploy
compares it with `daemon.socket`.

## `config.local.yaml`

The overlay holds only what must not be public. `config.local.example.yaml`
is the template; `toolbox dev bootstrap --config FILE` copies a file into place
with mode `0600` when no local file exists.

```yaml
user:
  password: change-me
  ssh_keys:
    - "{{ file(~/.ssh/id_ed25519.pub) }}"
```

| Key | Meaning |
| --- | --- |
| `user.password` | Plaintext, hashed with `openssl passwd -6` by the rootfs build; a value that already looks like a crypt hash is kept. `toolbox dev secrets hash` hashes it in the file. Unset leaves the account locked so only keys work. `toolbox dev config json` redacts it. |
| `user.ssh_keys` | A list whose entries are a public key, a path to a key file, or a `{{ file(PATH) }}` reference. `BuildConfig._expandKeys` resolves `~/` against `TEMPO_CONFIG_HOME`, then `HOME`, reads every non-comment line of each file, and fails on a missing file or an entry that is neither a key nor a path. |

A rootfs build with neither key set fails rather than shipping a guessable
credential, and the example password `change-me` is rejected by the firmware
input check. Any other key from `config.yaml` may also be overridden here for
one machine, since the merge is generic.

## `.env.example`

Host-side variables for the build and `toolbox dev`. Paths below are under
`packages/tempo_build/lib/src/` unless given in full.

| Variable | Default | Effect | Read by |
| --- | --- | --- | --- |
| `TEMPO_REPO` | discovered from the working directory | The checkout to operate on; `--repo` does the same per call. | `context.dart` |
| `TEMPO_FLUTTER_SDK` | discover the pinned SDK | An explicit Flutter SDK, tried before `build/sdks/flutter/<version>` and the FVM cache. | `context.dart` |
| `TEMPO_DAEMON_DART` | the `daemon.toolchain_version` SDK's `dart` | The Dart executable for daemon builds; it must report `daemon.dart_version`. | `daemon.dart`, `daemon_deploy.dart` |
| `TEMPO_CONFIG_HOME` | `HOME` | Base for `~/` in `user.ssh_keys`. The sudo re-exec of the rootfs build sets it to the developer's `HOME`. | `context.dart`, `rootfs.dart` |
| `TEMPO_DEVICE_HOST` | `networking.usb_gadget.address` without the suffix | The SSH host for `toolbox dev device` and `app attach`. | `device.dart`, `app.dart` |
| `TEMPO_DEVICE_USER` | `user.name` | The SSH account. | `device.dart` |
| `TEMPO_DEVICE_IFACE` | discovered | The host interface of the gadget link for `device link` commands; needed when several gadget interfaces exist. | `device_link.dart` |
| `TEMPO_SSH_OPTS` | `-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10` | Replaces the SSH options, split on whitespace. `ServerAliveInterval=5` and `ServerAliveCountMax=3` are always appended. | `device.dart`, `packages/toolbox_core/lib/live_device.dart` |
| `TEMPO_ROOTFS_HOST` | unset | `1` builds, stages or shells the rootfs on the host under `sudo -E` instead of in the rootful container. The container entry point refuses to run without it. | `rootfs.dart`, `packages/tempo_build/bin/rootfs_container.dart` |
| `TEMPO_USB_ENGINE` | beside the executable, then `build/toolbox/rust/release/tempo-usb` | The native USB helper. | `packages/tempo_usb/lib/src/native_engine.dart` |
| `TEMPO_USB_AGENT` | beside the engine, then `platform/firmware/DA.img` | The legacy download agent image. | `packages/tempo_usb/lib/src/native_engine.dart` |
| `TEMPO_TOOLBOX_EMULATOR` | unset | `1` starts Toolbox as the emulator; compiled builds use `--dart-define=TEMPO_TOOLBOX_EMULATOR=true`. | `toolbox/app/lib/emulator/launcher_native.dart` |
| `TEMPO_EMULATOR_VM_URL` | discovered from the URL file or the log | The VM service URL the emulator MCP server connects to. | `toolbox/tool/emulator/emulator_mcp.dart` |
| `TEMPO_EMULATOR_VM_FILE` | `~/.cache/tempo/emulator-vm.url` | Where the emulator publishes its VM service URL and where MCP and `emulator clean` look. | `toolbox/app/lib/emulator/emulator.dart`, `emulator_mcp.dart`, `emulator.dart` |
| `TEMPO_EMULATOR_LOG` | `~/.cache/tempo/emulator.log` | The `flutter run` log MCP searches for the URL. | `emulator_mcp.dart` |
| `TEMPOD_TEST_EXECUTABLE` | run the Dart source | A compiled host `tempod` for the subprocess tests. | `daemon/test/host_process_test.dart` |
| `TEMPOD_TEST_NATIVE_EXECUTABLE` | skip those tests | A host `tempod-native` for the native process tests. | `daemon/test/native_process_test.dart` |
| `TEMPOD_TEST_NATIVE_LIBRARY` | skip those tests | A host `libtempod_native.so` for the FFI tests; `toolbox dev daemon test` supplies it. | `daemon/test/native_control_test.dart`, `daemon.dart` |

Two more variables are set by the tooling for itself and are not meant to be
exported by hand: `TEMPO_TOOLCHAIN=1` marks a process already inside the
toolchain image so `Toolchain.run` executes directly
(`context.dart`, `rootfs.dart`), and `TEMPO_ROOTFS_LOCK_HELD=1` tells a
re-entered rootfs command that the checkout lock is already taken
(`rootfs.dart`).

## `.env.device.example`

Variables the services read on the device. The shipped units and the drop-ins
that rootfs staging writes from `config.yaml` set the production values; see
[Root filesystem](../platform/rootfs.md) and [tempod](../app/daemon.md).

| Variable | Default | Effect | Read by |
| --- | --- | --- | --- |
| `TEMPO_WIFI_INTERFACE` | first `/sys/class/net/*/wireless` | The interface `HostRadios` passes to `wpa_cli -i`. | `daemon/lib/src/services/host_radios.dart` |
| `TEMPO_VIDEO_SIZE` | no scaler | `WIDTHxHEIGHT` for flutter-pi's GStreamer video path, inserted as a `videoscale` filter. `tempo.service` sets `480x360`. | `app/flutter-pi/patches/0003-video-playbin-audio.patch` |
| `TEMPO_VIDEO_STATS` | off | Any presence logs video caps and frame statistics from the same plugin. | `app/flutter-pi/patches/0003-video-playbin-audio.patch` |
| `TEMPOD_API_URL` | `http://127.0.0.1:8765` | The daemon HTTP endpoint the player and radio client use. The daemon's own listen address comes from `--bind` and `--port`, which default to the same. | `app/lib/src/daemon_app.dart`, `packages/daemon_client/lib/src/radio_client.dart` |
| `TEMPOD_API_TOKEN` | unset | The controller credential. The daemon reads it only without `--token-file`; the clients fall back to it. | `daemon/bin/tempod.dart`, `daemon_app.dart`, `radio_client.dart` |
| `TEMPOD_API_TOKEN_FILE` | unset | A file holding that credential; takes precedence in the clients. Staging sets `/var/lib/tempod/credentials/api-token`. | `daemon_app.dart`, `radio_client.dart` |
| `TEMPOD_OWNER_TOKEN` | unset | The player's owner credential; must differ from the API token. The daemon reads it only without `--owner-token-file`. | `tempod.dart`, `daemon_app.dart` |
| `TEMPOD_OWNER_TOKEN_FILE` | unset | A file holding the owner credential, read by the player. | `daemon_app.dart` |
| `TEMPOD_PROFILE_HOME` | unset | Enables profile mode with this home; staging sets `/home/<user.name>`. `--profile-home` wins. | `tempod.dart` |
| `TEMPOD_PROFILE_USER` | `tempo` | The account that owns the profile files and runs `cadenced`. | `tempod.dart` |
| `TEMPOD_SD_ROOT` | `/mnt/sd` | The card mountpoint in profile mode. A bare directory is not a card. | `tempod.dart` |
| `TEMPOD_MEDIA_HOME` | profile home, then `HOME`, then the working directory | The media home reported to the player. `--media-home` wins. | `tempod.dart` |
| `TEMPOD_MEDIA_DATABASE` | unset | Listed in the file, but no code reads it; the library database belongs to `cadenced`. | none |
| `TEMPOD_SETTINGS_FILE` | unset | The settings file outside profile mode. Ignored in profile mode. | `tempod.dart` |
| `TEMPOD_SOCKET` | `daemon.socket` as baked in | The control socket for the native broker, the Dart client and the plymouth hand-off plugin. Ignored by the broker under systemd socket activation. | `daemon/native/src/settings.rs`, `packages/daemon_client/lib/src/tempod.dart`, `app/flutter-pi/plugins/plymouth_handoff.c` |
| `TEMPOD_DB` | `$STATE_DIRECTORY/tempod.db`, else `daemon.state_dir/tempod.db` | The native metrics database. `--db` wins. | `settings.rs` |
| `TEMPOD_INTERVAL` | `daemon.sample_interval` | Seconds between samples, at least 1. `--interval` wins. | `settings.rs` |
| `TEMPOD_RETENTION` | `7` | Days of samples kept; `0` keeps all. `--retention` wins. | `settings.rs` |
| `TEMPOD_RUNTIME_DIR` | `/run/user/<user.uid>` | The player user's PipeWire runtime directory for the `volume` and `output` ops. | `daemon/native/src/volume.rs` |
| `TEMPOD_BATTERY_SYSFS` | `/sys/class/power_supply/mt6323-battery`, else the first battery | The battery sysfs directory the sampler reads. | `daemon/native/src/metrics.rs` |
| `TEMPOD_BACKLIGHT_SYSFS` | `/sys/class/backlight/mt6323-backlight`, else the first backlight | The backlight sysfs directory. | `daemon/native/src/metrics.rs` |

The Dart daemon and the player also read variables the example file does not
list: `CADENCE_SOCKET`, default `/run/cadenced/media.sock`, and
`CADENCED_EXECUTABLE`, default `/usr/local/lib/cadenced/bin/cadenced`
(`tempod.dart`, `daemon_app.dart`); `XDG_CONFIG_HOME` for the
profile's config root (`tempod.dart`); `HOME` as a media home fallback
(`tempod.dart`); and systemd's `LISTEN_PID` and `LISTEN_FDS` for socket
activation (`tempod.dart`, `daemon/native/src/control.rs`). `tempod-native`
reads `STATE_DIRECTORY` for its database (`settings.rs`) and sets
`XDG_RUNTIME_DIR` when systemd has not (`daemon/native/src/lib.rs`).
`tempo-system` takes its uid and gid from the `TEMPO_UID` and `TEMPO_GID`
compile definitions in `platform/rootfs/tool/runtime.dart`, not from the
environment.
