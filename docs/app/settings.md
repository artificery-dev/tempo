# Settings system

The player's settings are data. One Dart literal in `tempo_core` describes
every section, row, control, default and binding key as a tree of
`SettingNode` values, and the screens, the quick settings sheet and the stored
file all read that one tree. A `Settings` store says what each path is worth
right now, a `SettingsBridge` forwards every change to whatever code is
registered under the row's `bind` key, and a `SettingsFile` writes the changed
values back to `settings.json` in the profile's config folder. On the device
that write goes through `tempod`, so the file survives the player being
restarted underneath it. [Settings](../getting-started/settings.md) describes
the same tree as a user sees it; this page is about the machinery.

## Components

| Where | What |
| --- | --- |
| `packages/tempo_core/lib/src/settings/setting_node.dart` | `SettingNode`, `SettingKind`, `SettingControl`, `SettingStore`, `SettingLayout`, `SettingOption`, `SettingCondition`, `SettingLocation` and the path index `SettingsTree`. |
| `packages/tempo_core/lib/src/settings/settings_tree.dart` | `settingsRoot`, the shipped tree, and `playerSettingsTree`, its index. |
| `packages/tempo_core/lib/src/settings/settings.dart` | `Settings`, the value store; `SettingChange`, `SettingSource`, `SettingsScope`. |
| `packages/tempo_core/lib/src/settings/setting_bindings.dart` | `SettingBindings`, `SettingsBridge`, `SettingCapabilities` and `PlayerSettings`, the player's own sinks and actions. |
| `packages/tempo_core/lib/src/settings/settings_file.dart` | `SettingsFile`: load, settle-timer save, remote read and write. |
| `packages/tempo_core/lib/src/settings/settings_app.dart` | `SettingsApp`, the dock entry that opens the root page. |
| `packages/tempo_core/lib/src/settings/settings_screen.dart` | `SettingsScreen`, one page of rows; `SettingScreens`, the registry of hand-written pages; the options and confirm pages. |
| `packages/tempo_core/lib/src/settings/setting_tile.dart` | The row widgets for each control. |
| `packages/tempo_core/lib/src/settings/time_zone_screen.dart` | `PlayerSettingScreens.install`, which registers every `screen:` key the player ships, and the time zone picker. |
| `packages/tempo_core/lib/src/settings/*_screen.dart` | The other hand-written pages: wallpaper, colours, radios, library folders, data storage, eject and format. |
| `packages/tempo_core/lib/src/app.dart` | `TempoApp.open`, the boot order: install bindings, load the file, apply everything, then watch. |
| `daemon/lib/src/services/settings_host.dart` | `SettingsHost`, the daemon's owner of the file behind `/api/v1/settings`. |
| `packages/daemon_client/lib/src/settings_client.dart` | `SettingsClient`, the app's `GET` and `PUT` of that route. |

## The tree

`settingsRoot` is a `SettingNode.group` with eleven sections under it, divided
by `SettingNode.divider` rows into Playback, Interface, Device, apps and
system:

| Section | Id | Holds |
| --- | --- | --- |
| Sound | `sound` | Volume, output, tone, volume leveling. |
| Playback | `playback` | Resume, gapless, crossfade, shuffle, repeat, seek. |
| Library | `library` | Folders, scan policy, sections. |
| Appearance | `appearance` | Theme, interface size, tint, colours, wallpaper, home screen. |
| Controls | `controls` | Wheel, feedback, buttons, button shortcuts, navigation. |
| Display | `display` | Brightness, dim and sleep. |
| Power | `power` | Battery and standby. |
| Connections | `connections` | Wi-Fi, Bluetooth, USB, file sharing, music server, remote access. |
| Storage | `storage` | Data location, usage, card, eject, format, backups. |
| Apps & Extensions | `extensions` | Applets. |
| System | `system` | Time and language, privacy, updates, developer, reset. |

Every node has a `kind`. A `group` is a page of children. A `setting` holds a
value and a `control`. An `action` does something when activated. An `info`
row is a reading. A `screen` names a hand-written page by key and may still
hold a value, as the time zone does. An `alias` shows another setting in a
second place by full path. A `divider` is a rule between cards.

| Control | Row | Stored as |
| --- | --- | --- |
| `toggle` | A switch. | `bool` |
| `choice` | A segmented control when two or three labels of at most eight characters fit, else a page of options. | The option's `value` |
| `duration` | A choice over lengths, always on a page. | Milliseconds, or `null` for never |
| `slider` | A track under the title; captures the wheel. | `num` |
| `stepper` | A number stepped in place; captures the wheel. | `num` |
| `color` | A swatch off the theme ramp. | The swatch name |
| `text`, `time`, `chord` | Declared with `SettingNode.pending`; rendered disabled. | |

The fields that shape behaviour are `id` (one lower-kebab path segment),
`defaultValue`, `bind` (the key of the code that answers), `screen`, `alias`,
`store`, `needs`, `when`, `pinnable` and `pinnedByDefault`, `danger` with
`confirm`, `oobe`, `icon` and `keywords`. `needs` names capabilities the row
requires or it is hidden. `when` is a `SettingCondition` parsed from a string
such as `/settings/display/dim-after != never`; a row whose condition fails is
shown disabled, never hidden. `store` is `user`, `device`, `session` or
`secret`; today only `secret` changes anything, and only on screen, where the
row reads `••••` instead of its value. `SettingNode.toJson` round-trips the
whole tree, which is why every field is a plain value.

`SettingsTree` indexes the tree by path from `/settings` down and refuses two
items at one path. `settings` is every node that holds a value, `defaults`
their fresh-install values, `pinnedByDefault` the quick settings pins, and
`resolve` follows an alias to its target.

## Values

`Settings` holds only what somebody has moved. `value(path)` answers the
stored value or the node's default, through an alias to its target.
`read<T>` adds a type floor: a stored value of the wrong shape reads as the
default rather than throwing into a screen, and `readInt`, `readDouble` and
`readDuration` cover JSON's loss of the int and double distinction.

`set(path, to, source:)` does three things in order: it stores the value, it
publishes to the `listen(path)` notifier for that one path, and it announces a
`SettingChange` on the synchronous `changes` stream. A value equal to the
default is removed from the map instead of stored, so a default that changes
in a later build reaches everyone who never touched the row. `restore` takes a
whole map, announcing each value that actually moved; paths the tree no longer
has are kept and announced to nobody. `resetAll` sets every stored path back
to its default, one change each.

`SettingSource` says who moved a setting: `settings`, `quick`, `oobe`,
`restore` or `system`. Bindings read it. The volume sink ignores `system`
changes, because those are the mixer reporting back what it took, and the
radio sinks do the same for the enabled switches the daemon's readings keep in
step.

## Bindings

`SettingBindings` is a static registry of sinks (`register`) and actions
(`registerAction`) by bind key. A later registration replaces an earlier one.
`SettingsBridge` listens to a `Settings` and calls `SettingBindings.apply` for
every change; a change whose key nobody answers is kept in `unanswered` (the
last 32) and logged as `settings: nobody answers <key>`. A setting with no
`bind` at all is never unanswered: being stored is what it does.

`PlayerSettings.install` registers the player's sinks and actions against a
`PlayerServices`, attaches the bridge, and pushes the library's folder and
scan settings straight into the library service. When a `RadioService` is
present it also adds the `wifi` and `bluetooth` capabilities and keeps the
two enabled switches in step with the radios' readings. The sinks registered
today move: library scan policy and roots; the radio switches; appearance
mode, scale, the three colour roles, page tint and glass; status bar icons;
wallpaper image, fit and palette index; wheel acceleration and sensitivity;
clock format and time zone; brightness, dim and sleep; volume level, the
new-device policy and feedback; home, dock and menu options; the full
filesystem switch; and the debug switches. The actions are `library.scan`,
`wallpaper.reset`, `appearance.resetColours`, `menu.reset`, `power.restart`
and `power.shutdown`. The reset actions write back through the store rather
than at the notifiers, so the file agrees with the screen.

Every other bind key in the tree is unregistered on purpose. `SettingsScreen`
reads `SettingBindings.keys` and draws those rows disabled, which is the
honest state for hardware and features still being brought up.

`SettingCapabilities.available` is the set behind `needs`. `wifi` and
`bluetooth` come from the radio service and `dev` follows the developer mode
switch; nothing adds `device`, so rows that need it stay hidden on every
build.

## Screens

`SettingsApp` is the dock's Settings entry and opens `SettingsScreen` on the
tree's root. Each group is one `SettingsScreen`, and a row's control lives in
the row: a switch is thrown there, a slider moved there. A row is hidden when
`Settings.visible` says a needed capability is missing, and disabled when
`Settings.enabled` says its `when` fails or its bind key is unregistered.
Choices that do not fit inline open `SettingOptionsScreen`; an action with a
`confirm` line opens `SettingConfirmScreen` and invokes its binding only from
there.

`SettingScreens` maps a `screen:` key to a widget builder. It starts empty so
a plugin can bring its own, and `PlayerSettingScreens.install`, called from
`TempoApp`'s `initState`, registers the player's pages. A key nobody has
registered opens `PlaceholderScreen`, which names the page and its path.

| Key | Page |
| --- | --- |
| `data-storage` | `DataStorageScreen`, see [Storage and profiles](storage.md). |
| `eject-sd`, `format-sd` | `SdEjectScreen`, `SdFormatScreen`. |
| `library-roots` | `LibraryFoldersScreen`. |
| `library-order` | The library branch of the menu tree. |
| `wifi-picker`, `wifi-known`, `bluetooth-devices` | `RadioScreen` in its three modes. |
| `time-zone` | `TimeZoneScreen`, areas first and then places. |
| `wallpaper-picker`, `wallpaper-palette` | The wallpaper pages. |

## Persistence

`SettingsFile` keeps the stored map as one JSON object keyed by setting path,
sorted by path so two files diff as a list of choices. `TempoApp.open` fixes
the boot order: install the bindings, `load` the file, `applyAll` so the
backlight and the rest catch up with what it says, and only then `watch`,
otherwise the load would schedule a write of what was just read. Writes sit
on a 400 ms settle timer, so a wheel-driven slider writes once when it stops;
`dispose` writes a pending change synchronously on the way out.

Where the bytes go depends on the binary:

| Binary | Path | Writer |
| --- | --- | --- |
| Emulator | `settings.json` under `Places.config`, which is `.config/tempo` in the emulated home folder on the host. | The app writes the file itself. |
| Device | `/home/<user>/.config/tempo/settings.json` | `SettingsClient` sends the whole map as a `PUT /api/v1/settings`; `SettingsHost` in `tempod` writes it. |

`SettingsHost` serialises writes, refuses a document over 64 KiB, writes to
`settings.json.tmp.<pid>` with a flush and renames it into place, and
publishes each accepted document on its `changes` stream, which is how the
Cadence coordinator picks up new library roots without the app telling it. A
failed remote save is retried after five seconds. A remote load that fails
leaves the defaults in place rather than overwriting choices; a local file
that is missing, unreadable or not an object does the same.

The data storage controller pauses the file while the profile moves:
`flushForStorageChange` writes what is pending and stops watching, and the
app calls `watch` again once the daemon reports the profile settled. The
storage policy itself is not a setting; it lives in the selector described in
[Storage and profiles](storage.md).

## Migration

There is no versioned migration step and no schema number in the file. What
the code relies on instead:

- A setting sitting at its default is absent from the file, so a new default
  applies to everyone who never moved the row.
- `restore` keeps values for paths the tree no longer has, so a file written
  by a newer build is not thrown away by an older one.
- `read<T>` and the sinks tolerate the wrong shape: a colour name the theme
  does not know falls back to the theme's own for that role, an unknown
  appearance mode or scale leaves the notifier where it is, and a number that
  became a double rounds.
- A bind key that moves in the tree keeps working, because the sink is looked
  up by key, not by path; only the stored path changes.

The wallpaper follows the same rule. `WallpaperSource.load` looks only in
`Places.config`, writes the bundled default there as `wallpaper.jpg` when the
folder has none, and reads nothing from the older `~/.wallpaper.<ext>`
location.
