# The emulator

The emulator is the player's own interface, `TempoApp` from `tempo_core`,
running inside the Toolbox with every hardware service replaced by a value
somebody can set by hand. It draws a Y2 body around the panel, turns the
wheel from the mouse and keyboard, and keeps a rig of battery, radio, card and
screen states beside it. It runs on the desktop as a window of its own, as a
panel inside the Toolbox, and as a route on a phone. A small MCP server drives
the running emulator over the Dart VM service so a script or an agent can
press buttons and read the screen without a window in the way.

## Components

| Where | What |
| --- | --- |
| `packages/tempo_build/lib/src/emulator.dart` | `toolbox dev emulator run`, `mcp` and `clean`. |
| `toolbox/app/.fvmrc` | The Toolbox's own Flutter pin, which the emulator runs on; it is independent of the device SDK. |
| `toolbox/app/lib/emulator/emulator.dart` | `EmulatorApp` and `EmulatorShell`: the frame, the control bar, the rig panel, the event log, the screenshot and the VM service publication. |
| `toolbox/app/lib/emulator/launcher_native.dart`, `launcher_web.dart` | The desktop secondary window, the embedded panel, the mobile route and the standalone entry point. |
| `toolbox/app/lib/emulator/src/rig.dart` | `Rig`: the mocked machine, its filesystem, card, library and playback. |
| `toolbox/app/lib/emulator/src/hardware.dart` | `EmulatorHardware`: the wheel and buttons by name, and the `ext.tempo.emulator` service extension. |
| `toolbox/app/lib/emulator/src/settings.dart`, `paths.dart` | What the emulator remembers between runs, and where. |
| `toolbox/app/lib/emulator/src/emulator_window.dart` | `DeviceGeometry` and `EmulatorWindow`: the body's proportions and the zoom. |
| `toolbox/tool/emulator/emulator_mcp.dart` | The MCP server. |
| `.mcp.json` | Registers that server as `tempo-emulator`. |
| `packages/tempo_core/lib/src/services/services.dart` | `PlayerServices`: the interface the rig fills in and the device fills from the kernel and `tempod`. |

## Running it

```sh
toolbox dev emulator run
toolbox dev emulator run --release
toolbox dev emulator run -d linux --dart-define=TEMPO_TOOLBOX_EMULATOR=true
```

`emulator run` discovers the SDK pinned in `toolbox/app/.fvmrc` and runs
`flutter run` in `toolbox/app` with `--dart-define=TEMPO_TOOLBOX_EMULATOR=true`
and `TEMPO_TOOLBOX_EMULATOR=1` in the environment. Unless `-d` or
`--device-id` is given it targets the host operating system. Every other
argument goes to `flutter run`, so hot reload and the usual flags work.
`startEmulatorEntrypoint` accepts any of the define, the variable or an
`--emulator` argument and starts the standalone emulator instead of the
Toolbox; without them the Toolbox starts and the emulator is a panel inside it.

On start the shell writes the VM service URL to
`~/.cache/tempo/emulator-vm.url`, or to `TEMPO_EMULATOR_VM_FILE`, which is how
the MCP server finds it. `emulator clean` deletes that file, the log at
`~/.cache/tempo/emulator.log`, and `build/toolbox/emulator`.

## Windows and frames

On Linux, macOS and Windows the emulator can live in a second native window
that shares the Toolbox engine and isolate, opened with Pop out and closed
with Dock emulator. The embedded and detached presentations reparent one keyed
subtree, so the player's navigator, services, playback and hardware state
survive the move. On Android and iOS the emulator is a route. The web build
has no emulator.

`DeviceGeometry` derives the body from the panel size: margin, bezel, the gap
to the wheel, the wheel diameter and the chin are all ratios of the panel
width so every zoom keeps the same silhouette. `EmulatorWindow` offers zooms
of 1, 1.5, 2, 2.5, 3 and 4 times life size, starting at 2, and asks the
display for its pixel density so that 1x is the physical size of a Y2 screen.

The control bar carries the zoom, Pop out or Dock emulator, Restart,
Screenshot and the rig toggle. Escape toggles the rig panel. Restart runs the
profile restart in process and keeps stored data. Screenshot renders the player
frame through a `RepaintBoundary` at twice the logical resolution and opens a
save dialog for the PNG; it is only offered on the desktop platforms. The
event log panel is a bounded session history with copy as text or JSON.

## Mocked services

The player reads its machine through `PlayerServices` and nothing else. On
the device `PlayerServices.device` fills it from `tempod` and the kernel; in
the emulator the rig fills it by hand. The defaults the rig starts with:

| Service | Emulator value |
| --- | --- |
| `battery` | 78 percent, not charging; a slider and a switch in the rig. |
| `wifi`, `bluetooth` | `MockOnlyRadios`: connected to `Neon Bramble` with three bars, and to `Sundial Buds`. |
| `storage` | Empty until a card is inserted from the rig. |
| `places` | A memory filesystem with `/etc`, `/usr` and `/proc` as furniture, the player's home mounted from `$XDG_DATA_HOME/tempo-toolbox/home`, and the card at `/mnt/sd`. |
| `screen` | `ScreenSwitch`; sleep is a shade over the panel and the body draws it dark. |
| `volume` | `VolumeSwitch`, which also controls the host FM audio stream. |
| `fmRadio` | `EmulatorFmRadio`: fictional stations from `MockFmRadio`, or the live `FmRadioSwitch`, selectable in the rig. |
| `output` | `OutputSwitch`: the rig plugs and unplugs the jack. |
| `feedback` | `FeedbackSwitch`: ticks and clicks are counted, not played. |
| `timeZone` | Absent; previewing a zone must not change the host clock. |
| `library` | `MediaLibrary`, the in-process library over `cadence_media`, opened once data storage is available. |
| `playback` | `MediaKitPlayback` over libmpv when the host has it, otherwise `SilentPlayback`. |

The card comes from one of two sources. `inMemory` is a card that exists and
has a name and forgets everything at the end of the session. `hostFolder`
hands a directory on the host to the player as its card; the default is
`$XDG_DATA_HOME/tempo-toolbox/sdcard`. The library's section roots follow the
card in and out of the slot, so a removed host-folder card is unreachable
even though its files are still on disk. Data storage in the emulator runs
the same `tempo_data` profile transaction as the device, with an in-process
owner restart in place of `tempod`; see
[Storage and profiles](../app/storage.md).

Off Linux the XDG folders are replaced by the application's support directory
with `config` and `data` subfolders. Mobile document providers give files
rather than a mount, so a mobile card import copies the selection into app
storage first.

## What is remembered

`EmulatorSettings` writes `$XDG_CONFIG_HOME/tempo-toolbox/emulator.json` four
hundred milliseconds after the last change and once more on close. It holds
the zoom, the appearance mode and UI scale, sleep inhibition, battery percent
and charging, the wifi and bluetooth readings, the FM mock preference and the
card's source, folder and inserted state. A missing or unreadable file leaves
the defaults in place.

## Driving it from outside

`EmulatorHardware` names the wheel: `press`, `hold`, `jog`, `page`, `down`
and `up`, with buttons `select`, `menu`, `next`, `previous`, `playPause`,
`volumeUp`, `volumeDown` and `power`. Menu and power are keys timed from
their own edges, so their long words come from a `down`, a real wait, and an
`up`. The shell registers the `ext.tempo.emulator` service extension with
actions `status`, `knows`, `pressNamed`, `down`, `up`, `jog` and `screen`;
`screen` walks the player's element tree and returns every visible string in
paint order, skipping offstage subtrees so the dock's hidden apps do not
answer.

The MCP server speaks JSON-RPC over stdio and exposes:

| Tool | What it does |
| --- | --- |
| `press` | A button by name; `hold: true` keeps it down for 1600 ms, past every threshold. |
| `jog` | One detent at a time, forty milliseconds apart; negative is up a list. |
| `spin` | The whole turn as one jog, so a list moves exactly that many rows. |
| `screen` | The panel as text. |
| `eval` | A Dart expression in the scope of a library whose URI contains the given substring. |
| `status` | Whether an emulator is reachable and where its VM service is. |

It finds the service from `TEMPO_EMULATOR_VM_URL`, then the URL file, then a
`flutter run` log at `TEMPO_EMULATOR_LOG` or `~/.cache/tempo/emulator.log`,
and confirms each candidate answers the emulator's own extension so another
Flutter process is never mistaken for it. Every call reconnects, so nothing
goes stale across a relaunch.

```sh
toolbox dev emulator mcp
```

`.mcp.json` registers the same script as `tempo-emulator` for an agent
session, with `TEMPO_EMULATOR_VM_FILE` pointed at the default URL file.

## Tests

`toolbox/app/test/emulator/` covers the launcher, the device body and wheel
track, the rig, the storage panel and data storage, the FM radio, the event
log, card import and the settings round trip, and runs with the rest of the
Toolbox suite under `toolbox dev workspace test` and `toolbox dev toolbox
check`. Under `FLUTTER_TEST` the rig uses a memory filesystem, opens no
library and plays nothing. See [Testing and checks](testing.md).
