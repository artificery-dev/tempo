# Emulator

The emulator is the player application running on a desktop, inside a drawn
Y2. It is not a second implementation of the interface: the screen is
`TempoApp` from `tempo_core` on a `PanelSurface` of the panel's own 480 by
360 pixels, the same widget tree the device runs under flutter-pi. What
differs is the machine underneath. On the device the player reads battery,
radios, card, backlight and library through `PlayerServices` fed by the
kernel and `tempod`; in the emulator those services are fed by hand from a
rig, so a battery at 3% or a card pulled mid-track is a switch rather than an
experiment. The emulator lives in the Toolbox app and shares its Flutter
engine, as a section of the main window, as a pop-out window on desktop, or
as the whole application when started with the emulator entrypoint.

## Components

| Where | What |
| --- | --- |
| `toolbox/app/lib/emulator/emulator.dart` | `EmulatorApp` and `EmulatorShell`: the device, its control strip and the expanded controls. |
| `toolbox/app/lib/emulator/launcher_native.dart`, `launcher_web.dart` | The entrypoint, the embedded page, the pop-out window and the web stub. |
| `toolbox/app/lib/emulator/src/emulator_window.dart` | `DeviceGeometry` and `EmulatorWindow`: the body's proportions, zoom and window size. |
| `toolbox/app/lib/emulator/src/device_body.dart`, `click_wheel_pad.dart`, `skin.dart`, `wheel_motion.dart`, `pressable.dart` | The drawn player: body, bezel, wheel, side keys and the light that follows a turn. |
| `toolbox/app/lib/emulator/src/rig.dart`, `rig_panel.dart`, `frame_settings_overlay.dart` | `Rig`, the simulated hardware, and the panels that set it. |
| `toolbox/app/lib/emulator/src/data_storage.dart` | `EmulatorDataStorage`: the profile selector over `tempo_data`, with an in-process restart. |
| `toolbox/app/lib/emulator/src/emulator_fm_radio.dart`, `mock_fm_radio.dart` | The tuner with fictional stations. |
| `toolbox/app/lib/emulator/src/settings.dart`, `paths.dart` | What is remembered between runs, and where. |
| `toolbox/app/lib/emulator/src/hardware.dart` | `EmulatorHardware`: the wheel and buttons by name, for scripts on the VM service. |
| `toolbox/app/lib/emulator/src/event_log.dart`, `event_log_panel.dart` | The bounded session log and the drawer that shows it. |
| `toolbox/app/lib/emulator/src/native_window.dart`, `emulator_host.dart` | The `tempo/emulator_window` channel and the transparent host app. |
| `toolbox/app/lib/main.dart`, `toolbox_ui.dart` | The router, the sections and where the emulator is mounted. |
| `packages/tempo_core/lib/src/services/services.dart` | `PlayerServices`, the boundary the rig fills in. |
| `packages/tempo_core/lib/src/services/library.dart` | `MediaLibrary` and `hostMediaService`: Cadence's media service hosted in process. |
| `packages/tempo_build/lib/src/emulator.dart`, `toolbox/tool/emulator/emulator_mcp.dart` | `toolbox dev emulator` and the MCP server over the VM service. |

## Where the emulator runs

The Toolbox is a `GoRouter` application with one route per
`ToolboxSection`: `player`, `settings`, `emulator` and `backup`, at
`/<section>`, with `/` and unknown names redirecting to `/player`. On the
web `emulatorAvailable` is false, `/emulator` redirects to the player
section, and the embedded page is a line of text asking for the native
Toolbox. The section rail stays usable during a USB operation only for the
operation's own section, the emulator and settings.

Once the emulator section has been shown, `ConnectionPage` keeps
`EmbeddedEmulator` mounted offstage beneath the other sections, so the
player keeps running, playing and scanning while the user flashes a device
or reads the log. The log drawer at the bottom of every section is
`EmulatorLogDock`, over the same `EmulatorEventLog` the emulator writes to.

On desktop the page can pop out. `DesktopEmulatorWindows` creates a native
`WindowController` from Flutter's windowing API, enabled through
`enable-windowing` in the app's `pubspec.yaml`, titled `Tempo Emulator`,
with a minimum of 320 by 440 and an initial size from `EmulatorWindow`.
`runToolboxApp` runs the app with `runWidget` and a `ViewCollection`: the
primary view holds the Toolbox, and the emulator window is a second `View`.
Both presentations build `MobileEmulator` under the same `GlobalKey`, so
popping out and docking reparent one subtree; the navigator, services,
playback and hardware state survive the move. While popped out, the embedded
page shows a card with **Show window** and a dock action.

Inside a native window the content uses the `tempo/emulator_window` method
channel, handled in the Linux, macOS and Windows runners, to configure the
view, set its size, close it and start a drag from the body of the player.
On Android and iOS `runToolboxApp` is a plain `runApp`, there is no pop-out,
and the emulator stays a section of the app.

The emulator entrypoint bypasses the Toolbox shell. `startEmulatorEntrypoint`
runs `EmulatorHost` with a standalone `MobileEmulator` when the arguments
contain `--emulator`, the environment has `TEMPO_TOOLBOX_EMULATOR=1`, or the
build defines `TEMPO_TOOLBOX_EMULATOR`; `toolbox dev emulator run` sets both
the define and the variable. `EmulatorHost` is a `WidgetsApp` with a
transparent colour and tomeui page routes, so only the device is opaque. See
[The emulator](../development/emulator.md) for running and driving it.

## Starting up

`MobileEmulator` initialises media_kit for video, publishes the Dart VM
service URI to `TEMPO_EMULATOR_VM_FILE` or `~/.cache/tempo/emulator-vm.url`,
records the application support directory, ensures the default card folder
exists, builds the `Rig`, loads the saved settings, sizes the window, opens
storage and only then begins saving settings on change. The player is shown
once the rig reports storage initialised; before that the panel says
`Opening storage…`.

`Paths` decides where things live. On Linux the emulator follows the XDG
layout the player itself uses; elsewhere the application support directory
stands in for the dot folders.

| What | Linux | Other platforms |
| --- | --- | --- |
| Settings | `$XDG_CONFIG_HOME/tempo-toolbox/emulator.json` | `<support dir>/config/emulator.json` |
| Emulated home | `$XDG_DATA_HOME/tempo-toolbox/home` | `<support dir>/data/home` |
| Default card folder | `$XDG_DATA_HOME/tempo-toolbox/sdcard` | `<support dir>/data/sdcard` |

## The device frame

`DeviceGeometry` derives every dimension of the body from the panel width:
the margin, the black bezel, the gap to the wheel, the deeper chin, the
wheel at 0.84 of the panel width and the corner radius. `EmulatorWindow`
turns a zoom into a panel size: the panel's 46 mm width at 96 logical pixels
per inch times the zoom, with the height taken from the 480 by 360 pixel
aspect rather than the driver's 35 mm, so the screen is exactly 4:3. The
zoom steps are 1, 1.5, 2, 2.5, 3 and 4, and 2 is the default. The embedded
page picks the largest zoom that fits its space without touching the
remembered pop-out zoom; a native window is resized to
`windowSize`, the body plus a 20 pixel surround, padding and the 54 pixel
control strip.

`DeviceBody` draws the plastic and sets the real screen into it. The panel
is wrapped in `ClipRect` and `IgnorePointer`: the Y2 has no touch screen, so
nothing reaches the player through a pointer, and what the player draws past
its edge, such as the dock's cover flow, stops at the glass. A scroll over
the body turns the wheel one detent per tick. The backlight is a coloured
box over the panel that fades in from the `ScreenService` when the player
sleeps. A left drag outside the wheel starts a window drag in a pop-out.

`ClickWheelPad` is the ring with its four buttons and centre, turned by
dragging around it at about twenty detents per turn, and lit where the
finger would be by `WheelMotion`, which every jog passes through so the
light and the selection never disagree. The side rail holds the volume
rocker and the power key on the right edge, each a quarter of the panel
height, pressed and released as edges so the player counts holds and repeats
exactly as it does from the real keys. `DeviceSkin` colours the body from
the theme's neutral swatch, silver in light and black in dark, with a bezel
that is black in both.

Around the device, `EmulatorShell` offers two presentations. The compact one
is the pop-out and the standalone entrypoint: the device and a narrow control strip with screenshot,
charging, WiFi, Bluetooth, card, zoom, the machine state overlay and a menu
with dock and restart. The expanded one is the embedded page: a header with
screenshot, restart and pop-out, the device, and the rig controls in a
sidebar at 720 pixels or wider, stacked below it otherwise. The machine
state overlay is pushed on the device's own `Navigator`, so it covers the
player and nothing else, and closes with Escape. Screenshots capture the
panel's repaint boundary at twice the logical resolution and ask for a save
location on desktop. The emulator follows the host's brightness and reports
it to `Appearance.systemBrightness`, which the player's own appearance
setting consults.

## The rig

`Rig` is a `ChangeNotifier` holding the notifiers `PlayerServices` reads.
Its defaults are a 78% battery not charging, WiFi connected to `Neon Bramble`
with three bars, Bluetooth connected to `Sundial Buds`, an empty card slot,
the backlight on and output on the speaker. The radios are `MockOnlyRadios`, a
`RadioService` that refuses to leave mocked mode, so the emulator never
touches the host's own WiFi or Bluetooth. Feedback is a `FeedbackSwitch` that
counts ticks and clicks without sound or motor. There is no time zone
service, so previewing a zone cannot change the host, and no card
maintenance controller.

The machine's filesystem is a `MountedFileSystem`: an in-memory tree with
`/etc`, `/usr`, `/proc`, `/mnt`, `/opt/tempo` and `/home/tempo` as
furniture, and two real filesystems mounted in. The player's home,
`/home/tempo`, is the host folder above, so what the emulated player writes
is still there tomorrow. The card is `/mnt/sd`, present only while the slot
is occupied, and comes from one of two sources:

| Source | What stands behind `/mnt/sd` |
| --- | --- |
| `inMemory` | A `MemoryFileSystem` with empty `Music`, `Podcasts` and `Audiobooks` folders, kept for the session so removing and reinserting keeps its contents. |
| `hostFolder` | A directory on this machine, the default card folder unless another is chosen. |

Inserting or removing is an event the player sees, as it would from the
hardware. Changing the source or the folder while a card is in the slot is an
eject followed by an insert, never a card that silently changed. Removing a
card stops playback first, as the device does when Cadence reports the
volume detached. On mobile, files picked through the document provider are
copied into the card folder's `Music` or `Movies` by extension, because a
provider gives files rather than a mount.

`EmulatorDataStorage` runs the same profile transaction as the device over
`tempo_data`'s `TempoStorageManager`, with the device profile under
`/home/tempo`, the selector file beside it, and the card as a root only when
an inserted card actually exists. A card arriving or leaving follows the
device's boot decision: a profile on the card, or none, restarts the player
in place; with the device profile active, a card that holds a profile under
the `yes` policy is taken up, and otherwise the card is offered unless the
policy is `no`. The restart
suspends the profile, closes the library, re-runs the startup decision and
bumps a generation that rebuilds the player subtree, keeping settings,
library and media.

The tuner is `EmulatorFmRadio`, which can front a live receiver or a
`MockFmRadio`; the rig constructs it with no hardware attached, so the mock
is always in use. The mock carries six fictional stations with programme
names and rotating radio text every eight seconds, a stereo flag, PI and PTY
codes, and a weak signal between stations.

Settings are one JSON file written 400 ms after the last change and
synchronously on close: zoom, appearance mode, UI scale, sleep inhibition,
the battery, the mocked WiFi and Bluetooth readings, the mock tuner
preference and the card's inserted state, source and folder. A missing or
unreadable file leaves the defaults in place.

## Library and playback

The emulator's library is `MediaLibrary`, opened on the profile's
`library.db`. Where that path resolves to the host filesystem it is used
directly; where the profile lives on a virtual card the database is bridged
through a temporary host file, imported when the library opens and exported
back when it closes, because SQLite needs a real path. Scan roots are the
host folders behind the card and the home, and the card's section folders
are offered only while a host-folder card is in the slot: the files are still
on the disk when the card is out, but the player must not reach them. An
empty library scans three seconds after opening and a full one is rechecked
after five.

`MediaLibrary` hosts Cadence's media service in this process through
`hostMediaService` from the `cadence_media` package: a `MediaDatabase` over
drift's native SQLite on a background isolate, a `LibraryScanner` under the
player's scan policy with artwork deferred to an `ArtworkQueue`, and a
`MediaService` answering the same requests the daemon does. The device
itself does not use this path; it browses through `cadenced` with
`CadenceMediaLibrary`, as described in
[Cadence integration](../app/cadence-integration.md). `tempo_core` depends
on `cadence_media` for the emulator and tests alone.

Playback is `MediaKitPlayback` over the host's libmpv when the desk has one,
wrapped in `SerializedPlayback`, and `SilentPlayback` with a line in the log
when it does not. The mixer is a `VolumeSwitch`, the output an
`OutputSwitch` the rig plugs and unplugs, and video goes through
`video_player_media_kit`.

## Reaching the hardware by name

Everything that presses the drawn wheel goes through one `WheelMotion`, and
`EmulatorHardware` gives it a name. While the shell is up, the static API
offers `press`, `hold`, `jog`, `page`, `down` and `up`, plus `pressNamed`,
`knows` and `buttonNamed` for the words a script would type: `select`,
`menu`, `next`, `previous`, `playPause`, `volumeUp`, `volumeDown` and
`power`. Menu and power are keys the player times from their own edges, so a
hold on them is a `down`, a wait and an `up`. `screenText` walks the
player's element tree and returns every visible string in draw order. The
same actions are registered as the service extension `ext.tempo.emulator`.

`toolbox/tool/emulator/emulator_mcp.dart` is an MCP server over stdio that
finds the running emulator's VM service, through `TEMPO_EMULATOR_VM_URL` or
by searching, and exposes `press`, `jog`, `spin`, `screen`, `eval` and
`status`, evaluating against the hardware library's scope and holding a
button for 1.6 seconds when asked. `toolbox dev emulator run`, `mcp` and
`clean` in `packages/tempo_build/lib/src/emulator.dart` start the app with
the pinned Toolbox SDK, run that server, and remove the published URI, the
log and `build/toolbox/emulator`. The developer workflow is in
[The emulator](../development/emulator.md).
