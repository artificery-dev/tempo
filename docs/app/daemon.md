# tempod

`tempod` is the privileged half of the player. The Flutter frontend runs as
the unprivileged `tempo` account and owns the screen and playback; anything
that needs root goes through `tempod`. It is two processes under one name: a
Dart service host that serves the authenticated HTTP and WebSocket API on
`127.0.0.1:8765`, and a Rust hardware broker that answers one-line JSON
requests on the Unix socket `/run/tempod/tempod.sock`. The Dart host owns
credentials, the settings file, the profile and SD card selection, device
observations, the host radio operations, the BlueZ player and the supervision
of `cadenced`. The broker owns the DRM hand-off, the backlight, the mixer, FM,
haptics, sounds, power and the metrics sampler. This page covers the Dart host
and the units that hold the pair together; the broker itself is described in
[Native broker](../daemon/native-broker.md).

## Components

| Where | What |
| --- | --- |
| `daemon/bin/tempod.dart` | The Dart entry point: option parsing, service construction in order, readiness and shutdown. |
| `daemon/lib/tempod.dart` | Exports `PlayerServer` and `DemoPlayer`. |
| `daemon/lib/src/services/credentials.dart` | `initializeCredentials`: first-boot creation of the two token files. |
| `daemon/lib/src/services/service_notify.dart` | `sd_notify` through `libsystemd.so.0`, and the ten minute `ProfileStartupDeadline`. |
| `daemon/lib/src/services/shutdown.dart` | `shutdownServices`: ordered cleanup with a five second bound per service. |
| `daemon/lib/src/services/device_monitor.dart` | `DeviceMonitor`: battery and SD card observations once a second. |
| `daemon/lib/src/services/settings_host.dart` | `SettingsHost`: the serialized owner of `settings.json`. |
| `daemon/lib/src/services/storage_host.dart`, `profile_access.dart` | Profile selection, datastore moves and the ownership pass over the profile tree. |
| `daemon/lib/src/services/remote_player.dart` | `RemotePlayer`: the proxy for the frontend's playback owner. |
| `daemon/lib/src/services/radio_host.dart`, `host_radios.dart`, `bluetooth_player.dart` | Host radio operations and the BlueZ AVRCP player, described in [Radio hosting](../daemon/radios.md). |
| `daemon/lib/src/services/cadence_*.dart`, `card_host.dart` | `cadenced` supervision, roots and card maintenance, described in [Cadence supervision](../daemon/cadence.md). |
| `daemon/lib/src/transports/http/` | The Relic server, event clients and the owner connection, described in [Event protocol and HTTP transport](../daemon/protocol.md). |
| `daemon/lib/src/native/native_control.dart` | The diagnostic-only FFI bridge to the broker library. |
| `daemon/native/` | The Rust broker crate, built as `bin/tempod-native` and `lib/libtempod_native.so`. |
| `daemon/systemd/` | `tempod.service`, `tempod-native.service` and `tempod.socket`, installed verbatim. |
| `packages/daemon_client/` | The frontend's transports: `Tempod` for the socket, and the HTTP clients. |
| `packages/tempo_build/lib/src/daemon.dart`, `daemon_deploy.dart` | `toolbox dev daemon`: build, test, check, clean and deploy, plus the generated drop-ins. |
| `config.yaml` `daemon:` | `dart_version`, `toolchain_version`, `socket`, `state_dir` and `sample_interval`. |

## Two processes

The Dart host and the Rust broker are separate processes on purpose. The Dart
VM on Linux reaps any child with `wait()`, so a Rust broker embedded in the
same process loses the exit statuses of its own children, such as `wpctl` and
`plymouth`, and reports `No child processes`. The `--native-library` option
still loads `libtempod_native.so` into the Dart process for isolated
diagnostic tests, but production never uses it: the Dart host reaches the
broker only through its socket, with the `Tempod` client from
`daemon_client`.

The socket protocol is as small as it gets. A client connects, writes one JSON
object on one line, reads one JSON object back, and the broker closes the
connection. Every reply carries `ok`; a false one carries `error`. The
operations are `ping`, `battery`, `drm-handoff`, `screen`, `volume`, `output`,
`sound`, `haptic`, `fm`, `timezone`, `eject-sd`, `format-sd`, `reboot` and
`poweroff`. The socket path is `daemon.socket` in `config.yaml`; the ARM build
bakes it into the broker, the `Tempod` client and the flutter-pi hand-off
plugin carry the same default, and `TEMPOD_SOCKET` overrides all three at run
time. The `Tempod` client allows twenty seconds per request, because an FM
seek can take fifteen.

## systemd units

| Unit | Role |
| --- | --- |
| `tempod.socket` | Holds `/run/tempod/tempod.sock` for systemd, mode `0660`, owner root, group set by a drop-in. Activates `tempod-native.service`. `RemoveOnStop=yes`. |
| `tempod-native.service` | `Type=exec`, runs `/usr/local/lib/tempod/bin/tempod-native`. Requires the socket and `tempo-modem-bootstrap.service`, and starts after both. |
| `tempod.service` | `Type=notify` with `NotifyAccess=main`, `TimeoutStartSec=30`. `ExecStartPre` initialises credentials; `ExecStart` runs `/usr/local/sbin/tempod --token-file ... --owner-token-file ... --radios --bluetooth-player`. Requires and follows `tempod-native.service`. |
| `tempo.service` | The frontend, in `platform/rootfs/overlay`. Requires and follows `tempod.service`, and follows `plymouth-start.service`. |

Both services use `Restart=always` with a two second delay,
`StateDirectory=tempod` and `RuntimeDirectory=tempod` with
`RuntimeDirectoryPreserve=yes`, so a service stop never removes `/run/tempod`
from under the listening socket. `tempod.service` runs as root and must not
be hardened with `User=` or a capability bounding set: `DRM_IOCTL_SET_MASTER`
in the hand-off needs `CAP_SYS_ADMIN`, and without it the boot never leaves
the splash.

The rootfs build and `toolbox dev daemon deploy` install the same three unit
files and write three drop-ins from `config.yaml`, with `user.name` as the
frontend account:

| Drop-in | Content |
| --- | --- |
| `tempod.socket.d/10-group.conf` | `SocketGroup=<user.name>`, so the frontend may connect. |
| `tempod.service.d/20-runtime.conf` | Replaces `ExecStartPre` with `--init-credentials --credential-group <user.name>`; sets `TEMPOD_PROFILE_HOME=/home/<user.name>`, `TEMPOD_PROFILE_USER`, `TEMPOD_SD_ROOT=/mnt/sd` and `TEMPOD_SETTINGS_FILE`. |
| `tempo.service.d/20-daemon.conf` | `TEMPOD_API_URL=http://127.0.0.1:8765`, `TEMPOD_API_TOKEN_FILE` and `TEMPOD_OWNER_TOKEN_FILE` for the frontend. |

`.env.device.example` lists every `TEMPOD_*` variable the two processes and
the frontend read, with the shipped defaults.

## Credentials

No image contains a token. `tempod --init-credentials` runs before every
start and creates `/var/lib/tempod/credentials/api-token` and `owner-token`
if they are missing: 32 bytes from `Random.secure()`, base64url encoded,
written to a temporary file and renamed into place. The directory is mode
`0750` and the files `0640`, both assigned to the credential group so the
frontend can read them and nothing else can. A `.lock` file takes an exclusive
lock for the duration. An existing file is kept; one that is not a regular
file, or is empty, is an error and is never replaced.

The API token admits controllers to every `/api/v1` route except the owner
endpoint. The owner token admits exactly one frontend to
`GET /api/v1/owner`, and the daemon refuses to start if the two are equal or
if an owner token is combined with `--demo-player`. Without an owner
credential the owner route answers 404. The daemon reads its tokens from
`--token-file` and `--owner-token-file`, falling back to `TEMPOD_API_TOKEN`
and `TEMPOD_OWNER_TOKEN`; the frontend reads `TEMPOD_API_TOKEN_FILE` and
`TEMPOD_OWNER_TOKEN_FILE` first and the plain variables second. Tokens travel
only in `Authorization: Bearer` headers, never in URLs.

## Startup order

At boot the units bring the pair up in this order: `tempo-modem-bootstrap`
and `tempod.socket`, then `tempod-native`, then `tempod`, then `tempo`. The
frontend therefore never starts before the API and the socket are both
answering.

Inside `tempod` the services come up in a fixed sequence:

1. Parse options and watch `SIGINT` and `SIGTERM`.
2. Start `DeviceMonitor`: every second it asks the broker for `battery`,
   finds an `mmcblk1` mount in `/proc/mounts`, its mount ID in
   `/proc/self/mountinfo`, the card CID from
   `/sys/class/block/mmcblk1/device/cid` and recent I/O from the block
   statistics. Any missing source publishes unknown rather than a guess.
3. In profile mode, set by `TEMPOD_PROFILE_HOME`, start the
   `ProfileStartupDeadline`. It sends `EXTEND_TIMEOUT_USEC` every five
   seconds from a fixed ten minute budget, because a pending datastore move
   runs here and can take that long.
4. Resolve the profile through `StorageHost` and `tempo_data`'s
   `TempoStorageManager`, applying any pending move before any owner opens
   the data. See [Storage and profiles](storage.md).
5. Run `ensureProfileAccess` over the profile's data and config roots: refuse
   symlinks anywhere in or above them, `chown` everything to the profile
   user, set directories to `0700` and files to `0600`, then verify as that
   user with `runuser` that the tree is readable and writable. FAT volumes
   may reject the `chmod`, so the verification is what counts.
6. Open `SettingsHost` on `settings.json` in the profile's config directory,
   or on `--settings-file` outside profile mode.
7. Start `cadenced` and its coordinator. A library failure here is logged as
   `Media library unavailable` and the daemon carries on, so settings and
   wallpaper keep working without a library.
8. Create `RemotePlayer`, and the BlueZ player when `--bluetooth-player` is
   set.
9. Bind `PlayerServer`, print `tempod listening at <url>`, and send
   `READY=1`.

The readiness call goes through `sd_notify` from the daemon's own PID, which
is why the unit has `NotifyAccess=main`: radio subprocesses such as
`bluetoothctl` inherit the environment, and the host strips `NOTIFY_SOCKET`,
`WATCHDOG_*` and `LISTEN_*` from their environment so a child can never stop
or ready the service.

## The plymouth to flutter-pi hand-off

flutter-pi starts while `plymouthd` still holds the DRM master. It renders its
first frame but cannot commit it. At that frame the app's
`PlymouthHandoff.armOnFirstFrame()` fires the `flutter_pi/plymouth_handoff`
channel, and the plugin connects to the broker socket, sends
`{"op":"drm-handoff"}` with its DRM fd attached as `SCM_RIGHTS`, and waits up
to ten seconds. The broker fades the splash with `plymouth update
--status=tempo-handoff`, runs `plymouth deactivate`, takes master on the
received fd, and answers `{"ok":true}`. Because master belongs to the shared
open file description, flutter-pi's fd is now master too and the paused
commit lands. The broker then watches the CRTCs until the app's frame is on
the panel and only then quits `plymouthd` with `--retain-splash`. The display
side, the theme and the full step list are in [Boot splash](../platform/splash.md).

## Shutdown

`SIGINT` or `SIGTERM` completes the daemon's stop future. `shutdownServices`
then closes each owner in order, each under a five second bound, logging
`shutdown: <name> stopping` and `stopped` or `incomplete`:

```
http, storage, bluetooth, demo, player, devices, cadence policy, cadenced, settings, native
```

The HTTP server goes first so no new work arrives while its dependencies
close: the owner connection is closed with code 4003, event subscribers with
4001, then the listener. If any step times out the daemon calls `exit(1)`
rather than idling until systemd's 90 second `SIGKILL`, so the journal shows
which owner blocked. An unexpected `cadenced` exit sets exit code 1 and
triggers the same stop, and `Restart=always` brings the whole group back.
Usage errors exit with 64.

A storage selection that needs a restart runs
`systemctl --no-block restart tempod.service tempo.service`; the frontend's
`Requires=` relation makes both stop jobs precede both start jobs, so the
move runs with no consumer open.

## Building and deploying

```sh
toolbox dev daemon build --target host
toolbox dev daemon build --target arm
toolbox dev daemon deploy [--dry-run]
toolbox dev daemon test | check | clean
```

The Dart host is compiled with `dart build cli`, because SQLite arrives as a
native asset through a build hook. The compiler is the Dart named by `daemon.dart_version`,
3.13.2, found inside the Flutter release named by `daemon.toolchain_version`,
3.47.2, or at the path in `TEMPO_DAEMON_DART`; this pin is independent of the
app's engine pairing. The ARM cross build of the broker passes `TEMPOD_DEFAULT_SOCKET`,
`TEMPOD_DEFAULT_STATE_DIR`, `TEMPOD_DEFAULT_INTERVAL` and
`TEMPOD_DEFAULT_USER_UID` from `config.yaml`, and `daemon/native/build.rs`
supplies matching fallbacks for a plain `cargo build`. The bundle lands in
`build/os/daemon/<target>/bundle` as `bin/tempod`, `bin/tempod-native`,
`lib/libtempod_native.so`, `lib/libsqlite3.so` and a `manifest.json` of
SHA-256 hashes. `--dart-only` skips the Rust half; the ARM build checks that
`bin/tempod` is an ARM32 ELF.

`deploy` verifies the ARM manifest and every hash, checks that
`tempod.socket`'s `ListenStream` equals `daemon.socket`, uploads a tarball
and verifies it again on the device, takes `/run/lock/tempo-daemon-deploy.lock`,
stops `tempo`, `tempod`, `tempod-native` and the socket, swaps
`/usr/local/lib/tempod` and the `/usr/local/sbin/tempod` link, installs the
units and drop-ins, starts the pair, fetches `/api/v1/player` with the device's
own API token, restarts the frontend if it was running and enables the units.
Any failure after the stop restores the previous runtime and units. The rootfs
build installs the same files into the image. `check` runs `cargo fmt`,
`clippy` and `dart analyze`; `test` runs the Rust tests and the Dart suite
against a host build of the library.

## Running on a desktop

```sh
toolbox dev daemon build --target host
export TEMPOD_API_TOKEN="$(openssl rand -hex 32)"
build/os/daemon/host/bundle/bin/tempod --demo-player --port 8765
```

`--demo-player` serves one in-memory track and never plays audio. `--bind`,
`--port`, `--tls-cert` with `--tls-key`, and `--allow-origin` shape the
listener; `--profile-home`, `--profile-user`, `--sd-root` and `--media-home`
select profile mode; `--radios` and `--bluetooth-player` enable the host
services, which talk to the real D-Bus and network stack. A local broker comes
from `cargo build -p tempod --bin tempod` and
`build/rust/debug/tempod --no-sampler --socket /tmp/tempo-dev.sock`, with the
Dart host's `--socket` pointed at the same path. `--help` lists everything.
