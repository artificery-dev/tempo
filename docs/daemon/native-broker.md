# Native broker

`tempod` is two processes. The Dart service in `daemon/bin/tempod.dart` owns
the HTTP API, the playback owner, settings, storage and Cadence. The native
broker in `daemon/native` is a Rust executable that owns everything needing
root and a device file: the DRM hand-off, the backlight, the mixer, the
haptic motor, the wheel sounds, the FM receiver, power and time zone changes,
and the battery and backlight metrics store. The two talk over one Unix
socket, `/run/tempod/tempod.sock`, which systemd holds. The player talks to
the same socket for the operations it needs directly, through the `Tempod`
class in `daemon_client`.

## Components

| Where | What |
| --- | --- |
| `daemon/native/Cargo.toml` | The `tempod` package: an `rlib` and `cdylib` named `tempod_native`, and the `tempod` binary. |
| `daemon/native/build.rs` | Bakes `daemon.socket`, `daemon.state_dir`, `daemon.sample_interval` and `user.uid` from `config.yaml` into the binary as defaults. |
| `daemon/native/src/lib.rs` | `run_legacy`: parse settings, take the listener, discover sysfs, start the sampler thread, serve. |
| `daemon/native/src/settings.rs` | Command line and environment precedence over the baked defaults. |
| `daemon/native/src/activation.rs` | Taking the socket systemd passed in, scrubbing `LISTEN_*`. |
| `daemon/native/src/control.rs` | `State`, the listener, one thread per connection, `dispatch` from op to module. |
| `daemon/native/src/protocol.rs` | The one-line JSON request and reply, the `Op` enum. |
| `daemon/native/src/fdpass.rs` | `recv_line`: the request bytes plus any `SCM_RIGHTS` descriptors. |
| `daemon/native/src/metrics.rs` | Sysfs discovery, `Sample`, the SQLite `Store` and the sampler loop. |
| `daemon/native/src/handoff.rs`, `screen.rs`, `volume.rs`, `output.rs`, `sound.rs`, `haptic.rs`, `power.rs`, `timezone.rs`, `radio.rs` | One module per op. |
| `daemon/native/src/bridge.rs`, `daemon/native/tempod_native.h` | The diagnostic C ABI. |
| `daemon/lib/src/native/native_control.dart` | `NativeControl`, the Dart side of that ABI. |
| `daemon/lib/src/services/device_monitor.dart` | `DeviceMonitor`: the once a second battery and card observation the API publishes. |
| `packages/daemon_client/lib/src/tempod.dart` | `Tempod.request`, the socket client both the Dart daemon and the player use. |
| `daemon/systemd/tempod.socket`, `tempod-native.service`, `tempod.service` | The socket unit and the two services. |
| `packages/tempo_build/lib/src/daemon.dart`, `daemon_native.dart` | `toolbox dev daemon build` and the host Cargo runner. |

## Two processes, one socket

`tempod.socket` listens on `/run/tempod/tempod.sock` as root with mode
`0660`, and the rootfs build writes a drop-in setting `SocketGroup` to
`user.name` so the player's account can connect. The socket unit names
`tempod-native.service` as its service. That unit runs
`/usr/local/lib/tempod/bin/tempod-native` after `tempo-modem-bootstrap.service`,
with `StateDirectory=tempod` and `RuntimeDirectory=tempod` preserved across
restarts so the socket file survives a service stop. `tempod.service`, the
Dart daemon, requires and starts after `tempod-native.service`. Both run as
root; the service comment explains why the hand-off cannot survive a
`User=` or a capability bounding set that drops `CAP_SYS_ADMIN`.

The split exists because of process reaping. The Dart VM on Linux reaps any
child with `wait()`, so a Rust `std::process` child living in the same
process can lose its exit status, and `wpctl` and `plymouth` then fail with
`No child processes`. The native broker therefore has its own process, and
Dart only ever opens the socket. `--native-library` on the Dart daemon loads
the same code as a shared library for isolated diagnostic tests; it is not
used on the device.

## Startup

`run_legacy` in `lib.rs` runs in this order, and the order matters:

1. Parse the command line and environment into `Settings`.
2. Set `XDG_RUNTIME_DIR` to the player user's runtime directory if it is not
   set, so `pipewire-alsa` and `wpctl` find that user's sound server. This
   happens while the process is still single threaded.
3. Take the listener. `activation::take_listener` accepts fd 3 when
   `LISTEN_PID` is this process and `LISTEN_FDS` parses, checks that it is an
   `AF_UNIX` stream socket, sets `CLOEXEC` and removes the `LISTEN_*`
   variables so nothing spawned later inherits them. With more than one
   descriptor it uses the first. Without activation, `control::bind` creates
   the parent directory, removes a stale socket file, binds, and sets mode
   `0660`. A path that exists and is not a socket is an error.
4. Discover sysfs and log the battery and backlight paths.
5. Start the `metrics` thread unless `--no-sampler` was given.
6. Serve forever: one thread named `control` per accepted connection.

The settings precedence is flag, then `TEMPOD_*` variable, then for the
database systemd's `STATE_DIRECTORY`, then the baked default.

| Flag | Environment | Default |
| --- | --- | --- |
| `--socket PATH` | `TEMPOD_SOCKET` | `daemon.socket`, `/run/tempod/tempod.sock`; ignored when socket-activated |
| `--db PATH` | `TEMPOD_DB`, else `$STATE_DIRECTORY/tempod.db` | `daemon.state_dir/tempod.db` |
| `--interval SECS` | `TEMPOD_INTERVAL` | `daemon.sample_interval`, 30 |
| `--retention DAYS` | `TEMPOD_RETENTION` | 7; 0 keeps everything |
| `--no-sampler` | | serve the socket only |

`build.rs` turns `TEMPOD_DEFAULT_SOCKET`, `TEMPOD_DEFAULT_STATE_DIR`,
`TEMPOD_DEFAULT_INTERVAL` and `TEMPOD_DEFAULT_USER_UID` into `env!()`
constants, validates them, and falls back to values mirroring `config.yaml`
for a plain `cargo build` or `cargo test`. The ARM build in
`packages/tempo_build/lib/src/daemon.dart` passes those variables from
`config.yaml`, so the shipped binary always carries the configured paths.

## The wire

One connection carries one request: a JSON object on one line ending in
`\n`, and exactly one JSON object back on one line, after which the broker
shuts the connection down. The request names its operation in `op`. Every
reply has `ok`, and `error` when `ok` is false. A request longer than 64 KiB
is refused, and a client that connects and says nothing is dropped after
five seconds.

`fdpass::recv_line` reads the line with `recvmsg` in chunks and harvests
`SCM_RIGHTS` control data from every chunk, because the kernel delivers the
descriptors with the read that consumes the first byte of the send. At most
four descriptors are accepted; more is `MSG_CTRUNC` and an error. Only
`drm-handoff` uses a descriptor; any others are closed when the handler
returns. `peer_credentials` reads `SO_PEERCRED` so the log can say which
pid and uid asked for a state change.

```sh
printf '{"op":"ping"}\n' | socat - UNIX-CONNECT:/run/tempod/tempod.sock
```

`Tempod.request` in `daemon_client` is the same exchange from Dart: connect,
write one line, read to end of stream, throw `TempodError` when `ok` is
false. Its timeout is twenty seconds because an FM seek can take fifteen.

## Operations

`control::dispatch` maps each `Op` to a module. The handlers share `State`,
which holds the latest sample, the sysfs paths, and one instance each of
`Screen`, `Volume`, `Haptic`, `Sound`, `Routing` and `Radio`. Each of those
serializes its own requests with a mutex, so two quick volume steps land in
order and two hand-offs cannot race each other's plymouth steps.

| `op` | Request fields | Module | What happens |
| --- | --- | --- | --- |
| `ping` | | | Replies with the crate version. |
| `battery` | | `metrics` | Reads the gauge and backlight now rather than returning the sampler's last word, stores the reading as the latest, and replies with the sample fields. |
| `drm-handoff` | one `SCM_RIGHTS` fd | `handoff` | Checks the fd is a DRM primary node, records each CRTC's framebuffer, asks plymouth to fade and deactivate, takes DRM master with retries on `EBUSY`, replies, then in a `handoff-finish` thread waits for the frontend's first commit before closing the fd and quitting plymouth. |
| `screen` | `on`, `brightness`, `fade_ms` | `screen` | Writes `brightness` and `bl_power` under the backlight's sysfs directory. Sleeping waits out the frontend's fade first; a newer request cuts that wait short. Only `op` is a query. |
| `volume` | `level`, `step` | `volume`, `output` | A query reads the cached PipeWire state; a change runs `wpctl` on `@DEFAULT_AUDIO_SINK@` and reads back. Replies `level`, `muted`, `device` and `hardware`. |
| `output` | `target` | `output` | Reports where sound goes from the DAC's jack switch and the PipeWire graph, lists `bluez5` sinks, and with `target` selects `speaker`, `headphones` or a sink by node name through `pw-cli` and `pw-metadata`. |
| `sound` | `name`, `speaker_only` | `sound` | Synthesizes and plays `tick`, `click` or `thump` through a PipeWire PCM kept open between sounds. |
| `haptic` | `pattern`, `ms`, `strength` | `haptic` | Plays the `regulator-haptic` rumble effect through force feedback. |
| `fm` | `on`, `frequency_khz`, `seek` | `radio` | The MT6627 receiver; see [Radio hosting](radios.md). |
| `reboot`, `poweroff` | | `power` | `systemctl --no-ask-password --no-block reboot` or `poweroff`, bounded to five seconds. |
| `timezone` | `zone` | `timezone` | Validates the name against `/usr/share/zoneinfo` and the `TZif` magic, then `timedatectl set-timezone` and a readback. |
| `format-sd`, `eject-sd` | `confirm` for format | `control` | Runs `/usr/local/lib/tempo-system/tempo-system` with that subcommand and no further argument. The player's card maintenance goes through the Dart `CardHost` instead; see [Cadence supervision](cadence.md). |

Anything else is answered `unknown op`. The `format-sd` request is refused
unless `confirm` is `true`.

## Metrics

`Sysfs::discover` takes `TEMPOD_BATTERY_SYSFS` and `TEMPOD_BACKLIGHT_SYSFS`
if set, else `/sys/class/power_supply/mt6323-battery` and
`/sys/class/backlight/mt6323-backlight`, else the first `power_supply` entry
whose `type` is `Battery` and the first backlight entry. A `Sample` is the
Unix time, `capacity`, `voltage_now` as `voltage_uv`, the raw `status`,
`charging` meaning `status == Charging`, the raw `brightness` and
`backlight_pct` from `max_brightness`. Missing files leave fields null.

The sampler thread opens `tempod.db` in the state directory with WAL and
`synchronous=NORMAL`, retrying at the sample interval until it can, creates
the `samples` table with an index on `ts`, prunes rows older than the
retention once at start and then every hour, and inserts one sample per
interval. The `battery` op shares the `latest` slot but never waits for the
sampler. The gauge itself is described in
[Power Management](../porting/power.md).

## Device observations

The Dart `DeviceMonitor` is what the API and Cadence see. `tempod.dart`
constructs it with a `Tempod` client on the configured socket and starts it
before the profile, Cadence and the HTTP server, and it refreshes once a
second, never overlapping reads. Each refresh builds one `DeviceSnapshot`:

| Field | Source |
| --- | --- |
| `batteryPercent`, `charging` | The `battery` op; a failed request publishes unknown. |
| `cardPath` | The first `/proc/mounts` line whose device matches `/dev/mmcblk1` or a partition of it, with octal escapes decoded. |
| `cardMountId` | The `/proc/self/mountinfo` entry mounted at that path from that device. A directory that exists without such an entry is not a card. |
| `cardSourceId` | `/sys/class/block/mmcblk1/device/cid`, when it is 32 hex digits, lowercased. |
| `cardIoBusy` | `/sys/class/block/mmcblk1/stat`: true when requests are in flight, else whether the counters moved since the last refresh of the same mount, else unknown. |

The snapshot is served at `GET /api/v1/device` and pushed on a broadcast
stream. `cardIdentity`, the CID or failing that the mount ID or path, feeds
`StorageHost.observeCard`. The mount ID is what makes eject and relocation
safe: paths repeat across reinsertions, mount IDs do not. The slot and the
CID are described in [Storage](../porting/storage.md).

## The diagnostic ABI

`tempod_native.h` declares ABI 1: `tempod_native_abi_version`,
`tempod_native_start(socket_path, activated_fd, error, error_capacity)` and
`tempod_native_stop(runtime)`. `bridge.rs` implements it without the
sampler. `start` with `activated_fd` of -1 refuses a path a daemon is already
answering on, then binds it; with a descriptor it checks for a listening
Unix socket, duplicates it with `CLOEXEC`, and closes the caller's copy only
on success. The runtime accepts on a non-blocking listener in a
`native-control` thread, hands each connection to a `native-request` thread
running the same `control::handle`, and caps in-flight handlers at 32.
Panics never cross the boundary; failures come back as a NUL-terminated
message in the caller's buffer.

`NativeControl.start` in Dart checks the ABI version, calls `start`, and
keeps the handle as an integer. `close` runs `stop` on a worker isolate
because stopping joins handlers that may be blocked on device I/O.
`tempod.dart` wires this up only when `--native-library` is given, taking
fd 3 when systemd passed exactly one socket.

## Building

`toolbox dev daemon build` compiles the Dart daemon with `dart build cli`,
then unless `--dart-only` runs Cargo for the library and the binary. The
`host` target uses `daemonHostCargo`, which refuses to run anywhere but
Linux. The `arm` target runs Cargo for `armv7-unknown-linux-gnueabihf` in
the toolchain container with the `TEMPOD_DEFAULT_*` values, the cross
compiler and the ARM `pkg-config` path set. Both copy
`libtempod_native.so` into the bundle's `lib/` and the binary into
`bin/tempod-native`, and write a `manifest.json` of hashes that the rootfs
build verifies before installing the bundle under `/usr/local/lib/tempod`.
`toolbox dev daemon test` runs `cargo test -p tempod`, builds the library,
and passes it to the Dart suite as `TEMPOD_TEST_NATIVE_LIBRARY`.
