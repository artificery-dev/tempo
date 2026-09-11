# Interface

The player's interface is a click-wheel shell drawn for one 480 by 360 panel.
`TempoApp` in `tempo_core` builds it: a fixed stack of input, sleep, shade
and notice layers around a dock of applets, each with a navigator of its
own, walking a menu tree that is data rather than widgets. Everything is
built from `tomeui`, a widgets-layer toolkit, and `tomeui_clickwheel`, which
turns the hardware's keys into intents and provides the wheel-driven list,
grid and rail. This page describes how those parts fit; the hardware path
from the wheel to evdev is in [Input](../porting/input.md), and the user's
view of it is in [Using the player](../getting-started/using-tempo.md).

## Components

| Where | What |
| --- | --- |
| `packages/tempo_core/lib/src/app.dart` | `TempoApp`, the widget stack, the media, volume and power handlers, and `IdleSleep`. |
| `packages/tempo_core/lib/src/panel.dart` | `Panel`, the fixed frame of reference, and `PanelSurface`. |
| `packages/tempo_core/lib/src/scale.dart` | `UiScale`, `UiScaleScope`, `chromeScale` and `panelRailWeight`. |
| `packages/tempo_core/lib/src/appearance.dart` | `Appearance`: mode, scale, swatches, the resolved theme, and `FixedScale`. |
| `packages/tempo_core/lib/src/theme_fade.dart` | `ThemeFade`, which softens a light change by holding the last frame. |
| `packages/tempo_core/lib/src/dock.dart` | `MenuDock`, `DockOptions`, `DockShell`, the stage and flow, `StatusBar`, `BarChrome` and `DockBar`. |
| `packages/tempo_core/lib/src/applet.dart` | `Applet` and `AppletState`, the per-app navigator, focus scope and memory. |
| `packages/tempo_core/lib/src/menu/` | `MenuNode`, `MenuTree`, `systemMenuRoot`, `MenuScreens`, `MenuListScreen` and `MenuGridScreen`. |
| `packages/tempo_core/lib/src/screens.dart`, `screens/` | `HomeScreen`, `PlaceholderScreen`, the now-playing widgets, and the Files, FM radio, music, collection and video screens. |
| `packages/tempo_core/lib/src/routes.dart`, `panel_bar.dart`, `content_surface.dart`, `list_row.dart`, `marquee_text.dart` | `PanelRoute`, `PanelScreen`, `PanelList`, `GridCard`, `ContentMessage`, `ListRow` and `MarqueeText`. |
| `packages/tempo_core/lib/src/status.dart`, `osd.dart` | The bar's readings, the home clock, the library footer, and the toast and OSD layer. |
| `packages/tempo_core/lib/src/shade.dart`, `services/screen.dart` | `ScreenShade`, `DimShade`, `ScreenSleep` and `ScreenService`. |
| `packages/tempo_core/lib/src/wallpaper.dart`, `wallpaper_library.dart`, `wallpaper_import.dart`, `wallpaper_palette.dart` | The wallpaper, backdrops and glass, the picker's folders, import and palettes. |
| `packages/tempo_core/lib/src/wheel_settings.dart`, `debug_menu.dart` | `WheelSettings` and `DebugSettings`. |

## The panel

`Panel` fixes the numbers every screen is laid out against: 480 by 360
pixels, 46 by 35 millimetres, and a device pixel ratio of `4800 / 1748`,
which is what flutter-pi derives from the connector's physical size. The
logical canvas is therefore 174.8 by 131.1 dp. `PanelSurface` puts the app on
exactly that canvas, overriding the host's `MediaQuery` with the panel's own
size, ratio, no text scaling and no insets. With no `size` it fills the
surface, which on the device is the identity; a host that names a size gets
the panel drawn at that size and centred in whatever room is left.

## The widget stack

`TempoApp._app` builds one tree, top to bottom:

| Layer | Role |
| --- | --- |
| `SettingsScope`, `PlayerServicesScope` | The settings store and the machine's services for everything below. |
| `TomeApp` | The theme from `Appearance.theme` and the root navigator, whose home is `DockShell`. |
| `ThemeFade` | Holds the last frame as a still and fades it out when the light changes. |
| `UiScaleScope` | The chosen `UiScale`, above the navigator so every route sees it. |
| `IdleSleep` | The clock that dims and then sleeps the screen. |
| `ClickWheelInput` | The hardware's keys as intents, with the app's media, volume, power and feedback handlers. |
| `WheelAcceleration` | The fast-spin tier, on or off from the wheel settings. |
| `ScreenShade` | The black the UI fades to when the screen sleeps, with `DimShade` under it. |
| `Stack` | The shell, then `VolumeToasts`, `OutputToasts`, `CardToasts`, `OsdLayer`, and the frame counter when `DebugSettings.frameCounter` is on. |

Dialogs that arrive from outside a screen, such as the data storage prompt
and the audio route question, are pushed on the root navigator through
`TempoApp._navigator` with a theme at `UiScale.regular`.

## Wheel input handling

`ClickWheelInput` matches keys by physical identity and dispatches intents.
`JogIntent` walks focus by default and is overridden by any `WheelList`,
`WheelGrid` or `WheelRail` in focus. The centre button is `ActivateIntent`
on a press and `ActivateHoldIntent` on a hold. Menu is `WheelBackIntent`,
which pops the nearest navigator, and `WheelMenuIntent` when held. The media
buttons and the volume rocker speak past focus. Every button has two words,
and a press speaks on release so a hold is never also a press; the volume
keys speak on the way down and repeat while held.

`TempoApp` answers the words that reach past the screens:

| Word | Answer |
| --- | --- |
| Play, previous, next | Toggle, previous or next on `VideoPlayback.active` or `services.playback`; on an FM session, power and seek instead. |
| Play held | Stop. Previous or next held seeks ten seconds; flutter-pi never repeats a held key, so it is one jump per hold. |
| Volume rocker | `volume.nudge`, and the volume OSD while the screen is awake. |
| Power, one tap | Sleep or wake the screen. |
| Power, two taps | Toggle the dock. |
| Power held | The power dialog, with the dock put away first. |
| Any word | `services.feedback.word`, and the idle clock restarted. |

Asleep, the wheel says nothing and the centre button only wakes; the media
buttons, the rocker and the power chord still speak. `WheelSettings.feel`
carries the sensitivity setting as `rowsPerDetent`: one row per click at
High, a half at Medium, a third at Low, with the fraction carried so a firm
wheel still arrives. `WheelSettings.feel.acceleration` follows the
acceleration setting. `panelRailWeight` is one, so every rail turns at the
same rate.

Home has its own answers. With a track loaded the centre button switches
the wheel between volume and scrubbing, where a detent seeks five seconds
and a page thirty; idle, it opens the dock. Menu on home opens the dock too,
since there is nothing to back out of.

## The dock and applets

The dock is the top of the system menu as a row of icons along the bottom,
and the switcher between the apps behind them. `MenuDock.required` is
`/home`, `/apps`, `/library` and `/settings`, always present. `pins` are
paths the user adds beside them, `/apps/files` by default, and `order` is
the saved arrangement of both. An unpinned app opened from Apps goes into
`opened` and keeps its own stage for the session; `close` ends it.

`DockShell` resolves those into `Applet`s, one per entry, each holding a
`GlobalKey<NavigatorState>`, a `FocusScopeNode`, a `RouteObserver` and an
`AppletState`, a small JSON store under the applet store that the Files app
uses for its open folders. Every applet stays mounted while another is on
stage, so switching back lands where the user left. When
`MenuOptions.remember` is off the app just left is popped to its root on the
way out. Settings is wrapped in `FixedScale(chromeScale)` outside its
navigator, since it is where the size is chosen from.

While the dock is up the stage steps back to fit between the bar and the
dock, using `bandExtent` and `dockExtent` measured at the chrome scale, and
the apps flow past like covers as the box moves. `DockOptions.flow` chooses
turned covers or flat pages, and `DockOptions.atRoot` decides whether back
at an app's root brings the dock up. Choosing an item puts the dock away and
closes the flow on the chosen cover. The dock itself is glass at
`chromeScale` whatever the lists are set to, and its focus node reclaims the
wheel from any screen that takes focus while it is showing.

## The menu tree

`systemMenuRoot` is a `MenuNode` literal whose shape round-trips through
`toJson` and `fromJson`. A node has an `id`, a `label`, an icon `hint`, a
`screen` key for a leaf, an optional `layout` for a branch, and `children`.
`MenuTree` indexes every node by slash-joined path.

| Path | Screen |
| --- | --- |
| `/home` | `home`, which goes back to the dock's home rather than pushing. |
| `/apps/files`, `/apps/fm-radio`, `/apps/store` | `files`; `fm-radio`, an action; none. |
| `/library/music/playlists`, `songs`, `albums`, `artists` | none; `songs`; `albums`; `artists`. |
| `/library/podcasts`, `recordings`, `audiobooks`, `movies`, `shows` | A `CollectionScreen` for each section. |
| `/settings` | `settings`, which opens the separate settings tree. |

`MenuScreens` maps keys to builders: pages under `register`, routes such as
the power dialog under `registerRoute`, and actions such as opening FM radio.
A later registration replaces an earlier one, which is how a plugin takes a
screen over. A leaf with no key, or an unknown key, opens
`PlaceholderScreen` with its path on it, so an unfinished branch is walkable.

A branch shows as `MenuListScreen` or `MenuGridScreen` according to its own
`layout` or `MenuOptions.view`; `/library` uses `LibraryMenuScreen`, which
reorders sections from `/settings/library/order`. `openMenuEntry` pushes one
route per activation, hands home and pinned apps to the dock instead of
opening a copy, and opens a leaf chosen inside Apps as its own stage. Pages
move with `PanelRoute`, a slide in from the right with the old page leaving
to the left, so two translucent pages are never over each other.

## Screens

`PanelScreen` is the shape of every list screen: it publishes a `BarChrome`
with the page's title and backdrop, and pads its child below the bar.
`PanelList` wraps `WheelList` so each row is a settings-style card with the
scale's `cardGap` around it; `ListRow` is the row itself, a glyph, a name
and a chevron when the row leads somewhere. `MarqueeText` ellipsizes a line
until the wheel is on it and then walks it past twice. `GridCard` and
`ContentMessage` give grid cells and empty states the same card.

`HomeScreen` is the root of the Home applet: the wallpaper seen whole, the
readings unbacked on it, and the clock in the middle. With a track loaded the
cover fills the top, the words take a `NowPlayingCard` along the bottom, and
the clock moves into the bar's title slot when `HomeOptions.barClock` is on.
A video or FM session replaces it with `VideoNowPlaying` or
`FmRadioNowPlaying`. `LibraryFooter` shows a line under it while the library
takes in new music.

## UI scale

`UiScale` fixes the row heights, bar height, grid, spacing, icon sizes and
typography. `regular` is the default; `compact` and `large` are the other
two choices under Interface Size.

| Scale | Row | Bar | Grid | Body type |
| --- | --- | --- | --- | --- |
| `compact` | 45 px, seven rows | 40 px | three columns, 106 px cells | 7 dp |
| `regular` | 53 px, six rows | 40 px | three columns, 160 px cells | 8 dp |
| `large` | 80 px, four rows | 40 px | three columns, 160 px cells | Tome's 14 dp |

Dialog and content widths are fixed at every scale, since the panel is the
panel. `chromeScale` is `regular`: the status bar, the dock and the settings
screens are always drawn at it, through `FixedScale`, so the chrome lines up
with itself at every depth. `UiScale.theme` mixes the Tome theme at that
scale from a brightness and the three swatches.

## The status bar and notices

`StatusBar` sits at the top at `barHeight`, reads the chrome of the page on
stage, and hides for a page whose `BarChrome.visible` is false, such as
immersive video. Its ground is the page's surface tone, or nothing on home,
and becomes the glass band while the dock is up. The title slot shows the
page's title, the app's name, the clock, or nothing, as the chrome says; while
the dock is up it names `MenuDock.preview`. The trailing readings follow
`StatusReadings`: battery icon and percent, WiFi and Bluetooth icons, the
play glyph, and whether idle icons are hidden.

Notices share `OsdToast`, a glyph, a body and a short word on a dark
translucent card low on the panel. `Osd` holds one slot with a clock; a new
notice replaces the last, and `OsdLayer` fades it in and out and leaves the
tree when the slot is empty. `VolumeToasts` shows the level as a square with
a bar, `OutputToasts` where the sound went, and `CardToasts` a card coming or
going.

## Sleep, dim and the shade

`ScreenSleep.after` is thirty seconds and `dimAfter` fifteen; `inhibited`
holds the clock, and `VideoPlayback.keepAwake` does the same. `IdleSleep`
winds both timers from the last word and from a wake, dims at the first and
sleeps at the second. `ScreenService.fade` is 400 ms and `minBrightness` is
10 percent. On the device `DeviceScreen` sends the `screen` op to `tempod`:
going dark the value moves at once so the frame fades before the backlight
goes out, and waking the backlight comes on before the value moves. A dim
drops the raw level to half, `dimLevel`, below which the PWM flickers.

`ScreenShade` sits above the navigator so sleep is not a route: the UI under
it keeps its stack and focus, its tickers stop, and once lifted the shade
leaves the tree. `DimShade` is the lighter wash at `depth` 0.45 under it.

## Theming and wallpaper

`Appearance.mode` is `dark` by default, or `light`, or `auto`, which is light
between sunrise and sunset for `Appearance.place`, the place the chosen time
zone stands for, with one timer set to the next crossing. Without a place,
auto follows `systemBrightness`. `primary`, `accent` and `neutral` are swatch
names and default to `wallpaper`, meaning the slot follows the palette read
off the picture on screen. `Appearance.theme` resolves all of it with the
scale and is what `TomeApp` wears; `ThemeFade` softens the change.

`WallpaperSource` looks for `wallpaper.<ext>` in the profile's config folder,
trying `png`, `jpg`, `jpeg`, `bmp`, `webp` and `gif` in that order, and
otherwise shows the bundled swirl, the same field the splash draws, writing it
there as `wallpaper.jpg` when `installDefault` is set. `adopt` takes a picture
in through `Wallpapers.take`, scaled to cover the panel and stored as the
player's own file, and reads its palettes in the same pass. `fit` is contain,
cover or centre. `WallpaperLibrary` offers the `Wallpapers` folder on the
card, in the home and under the home's Pictures, browsed as folders rather
than flattened.

One `Wallpaper` sits under the navigator. What a page puts between itself and
it is its `Backdrop`: `clear` for home, `cards` for a settings page,
`translucent` for a wash of the page colour, or `opaque`. `Backdropped.tint`
is Page Tint, a tone from 0.4 to 1 with 0.88 shipped, and `Glass.enabled` is
Translucent Surfaces: on, a surface is drawn at 0.75 opacity, or 0.45 for a
cover beside the one in focus; off, it is solid. Nothing blurs, because the
panel's GPU has no blur to give. The dock and the bar are `Glass`, the same
tone with a hairline rim.
