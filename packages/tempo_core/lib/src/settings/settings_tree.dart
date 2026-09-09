import 'setting_node.dart';

/// The player's settings, as data.
///
/// Eleven top-level sections group settings by purpose. Each item retains
/// its binding key when moved, while its path follows its current location.
/// Controls without an available implementation remain disabled.
///
/// A Dart literal for now. The shape is [SettingNode.toJson]'s, so a JSON
/// file, a plugin's subtree or a user's rearrangement is a different
/// source for the same tree, not a different tree.
const SettingNode settingsRoot = SettingNode.group(
  id: 'settings',
  label: 'Settings',
  icon: 'settings',
  children: [
    SettingNode.divider(id: 'div-playback', label: 'Playback'),
    _sound,
    _playback,
    _library,
    SettingNode.divider(id: 'div-interface', label: 'Interface'),
    _appearance,
    _controls,
    SettingNode.divider(id: 'div-device', label: 'Device'),
    _display,
    _power,
    _connections,
    _storage,
    SettingNode.divider(id: 'div-apps'),
    _extensions,
    SettingNode.divider(id: 'div-system'),
    _system,
  ],
);

/// [settingsRoot], indexed by path.
final SettingsTree playerSettingsTree = SettingsTree(settingsRoot);

// ---------------------------------------------------------------------------
// Appearance
// ---------------------------------------------------------------------------

const _appearance = SettingNode.group(
  id: 'appearance',
  label: 'Appearance',
  icon: 'palette',
  summary: 'Customize the theme, interface size, colors, and wallpaper',
  children: [
    SettingNode.choice(
      id: 'mode',
      label: 'Theme',
      summary: 'Use a light or dark theme, or switch at sunrise and sunset',
      icon: 'contrast',
      bind: 'appearance.mode',
      defaultValue: 'dark',
      pinnedByDefault: true,
      oobe: 'welcome/40',
      keywords: ['sunrise', 'sunset', 'night'],
      options: [
        SettingOption(
          value: 'auto',
          label: 'Auto',
          summary: 'Use light during the day and dark at night',
        ),
        SettingOption(value: 'light', label: 'Light'),
        SettingOption(value: 'dark', label: 'Dark'),
      ],
    ),
    SettingNode.choice(
      id: 'scale',
      label: 'Interface Size',
      summary: 'Adjust text and control sizes throughout the interface',
      icon: 'text',
      bind: 'appearance.scale',
      defaultValue: 'regular',
      oobe: 'welcome/50',
      keywords: ['text size', 'rows', 'density'],
      options: [
        SettingOption(
          value: 'compact',
          label: 'Compact',
          summary: 'Smaller text and controls; fits more items on screen',
        ),
        SettingOption(
          value: 'regular',
          label: 'Regular',
          summary: 'Medium text and control sizes',
        ),
        SettingOption(
          value: 'large',
          label: 'Large',
          summary: 'Larger text and controls; fits fewer items on screen',
        ),
      ],
    ),
    SettingNode.slider(
      id: 'tint',
      label: 'Page Tint',
      summary: 'Adjust the contrast between surfaces and the page background',
      icon: 'paintbrush',
      bind: 'wallpaper.tint',
      defaultValue: 88,
      min: 40,
      max: 100,
      step: 4,
      unit: '%',
      keywords: ['shade', 'tone', 'contrast'],
    ),
    SettingNode.toggle(
      id: 'glass',
      label: 'Translucent Surfaces',
      summary: 'Allow the wallpaper to show through cards and panels',
      icon: 'image',
      bind: 'wallpaper.glass',
      defaultValue: true,
    ),
    SettingNode.divider(id: 'div'),
    SettingNode.group(
      id: 'colours',
      label: 'Colors',
      icon: 'swatch-book',
      summary: 'Choose primary, accent, and neutral interface colors',
      children: [
        SettingNode.color(
          id: 'primary',
          label: 'Primary Color',
          summary: 'Color used for selected and focused controls',
          bind: 'appearance.primary',
          defaultValue: 'wallpaper',
        ),
        SettingNode.color(
          id: 'accent',
          label: 'Accent Color',
          summary: 'Secondary color used for interface highlights',
          bind: 'appearance.accent',
          defaultValue: 'wallpaper',
        ),
        SettingNode.color(
          id: 'neutral',
          label: 'Neutral Color',
          summary: 'Colors used for backgrounds, text, and dividers',
          bind: 'appearance.neutral',
          defaultValue: 'wallpaper',
        ),
        SettingNode.action(
          id: 'reset',
          label: 'Reset Colors',
          summary:
              'Set all three theme colors to Auto, using the wallpaper palette',
          bind: 'appearance.resetColours',
          pinnable: false,
        ),
      ],
    ),
    SettingNode.group(
      id: 'wallpaper',
      label: 'Wallpaper',
      icon: 'image',
      summary: 'Choose the background image, its layout, and its color palette',
      children: [
        SettingNode.page(
          id: 'image',
          label: 'Image',
          summary: 'Choose the image displayed behind the interface',
          screen: 'wallpaper-picker',
          bind: 'wallpaper.image',
        ),
        SettingNode.page(
          id: 'auto-palette',
          label: 'Palette',
          summary: 'Choose interface colors extracted from the wallpaper',
          screen: 'wallpaper-palette',
          bind: 'wallpaper.autoPalette',
          defaultValue: 0,
          keywords: ['color', 'accent', 'from wallpaper'],
        ),
        SettingNode.choice(
          id: 'fit',
          label: 'Fit',
          summary: 'Choose whether to fit, crop, or center the wallpaper',
          bind: 'wallpaper.fit',
          defaultValue: 'contain',
          options: [
            SettingOption(value: 'contain', label: 'Contain'),
            SettingOption(value: 'cover', label: 'Cover'),
            SettingOption(value: 'centre', label: 'Center'),
          ],
        ),
        SettingNode.action(
          id: 'reset',
          label: 'Reset Wallpaper',
          summary: 'Restore the original background image',
          bind: 'wallpaper.reset',
          pinnable: false,
        ),
      ],
    ),
    SettingNode.group(
      id: 'status-bar',
      label: 'Status Bar',
      icon: 'panel-top',
      summary: 'Choose which indicators appear at the top of the screen',
      children: [
        SettingNode.toggle(
          id: 'battery-icon',
          label: 'Battery Icon',
          summary: 'Show the battery level and charging state',
          bind: 'status.batteryIcon',
          defaultValue: true,
        ),
        SettingNode.toggle(
          id: 'battery-percent',
          label: 'Battery Percentage',
          summary: 'Show the remaining battery as a number',
          bind: 'status.batteryPercent',
          defaultValue: false,
        ),
        SettingNode.toggle(
          id: 'wifi-icon',
          label: 'Wi-Fi Icon',
          summary: 'Show the Wi-Fi state and signal strength',
          bind: 'status.wifiIcon',
          defaultValue: true,
          needs: {'wifi'},
        ),
        SettingNode.toggle(
          id: 'bluetooth-icon',
          label: 'Bluetooth Icon',
          summary: 'Show the Bluetooth state and connection',
          bind: 'status.bluetoothIcon',
          defaultValue: true,
          needs: {'bluetooth'},
        ),
        SettingNode.toggle(
          id: 'play-glyph',
          label: 'Playback Icon',
          summary: 'Show whether playback is playing or paused',
          bind: 'status.playGlyph',
          defaultValue: true,
        ),
        SettingNode.toggle(
          id: 'hide-idle',
          label: 'Hide Inactive Icons',
          summary: 'Hide Wi-Fi and Bluetooth icons when switched off',
          bind: 'status.hideIdle',
          defaultValue: true,
        ),
      ],
    ),
    _home,
  ],
);

// ---------------------------------------------------------------------------
// Home appearance and navigation
// ---------------------------------------------------------------------------

const _home = SettingNode.group(
  id: 'home',
  label: 'Home Screen',
  icon: 'house',
  summary: 'Customize the Home clock and Now Playing artwork',
  children: [
    SettingNode.toggle(
      id: 'clock',
      label: 'Clock',
      summary: 'Show the clock on the Home screen',
      bind: 'home.clock',
      defaultValue: true,
    ),
    SettingNode.toggle(
      id: 'bar-clock',
      label: 'Clock While Playing',
      summary: 'Show the clock in the status bar during playback',
      bind: 'home.barClock',
      defaultValue: true,
      when: SettingCondition(
        path: '/settings/appearance/home/clock',
        value: true,
      ),
    ),
    SettingNode.choice(
      id: 'artwork',
      label: 'Artwork',
      summary: 'Choose how artwork appears on the Now Playing screen',
      bind: 'home.artwork',
      defaultValue: 'fit',
      options: [
        SettingOption(value: 'fill', label: 'Fill'),
        SettingOption(value: 'fit', label: 'Fit'),
        SettingOption(value: 'off', label: 'Off'),
      ],
    ),
  ],
);

const _navigation = SettingNode.group(
  id: 'navigation',
  label: 'Navigation',
  icon: 'list',
  summary: 'Configure menu navigation, layouts, the dock, and Quick Settings',
  children: [
    SettingNode.choice(
      id: 'view',
      label: 'Default View',
      summary: 'Choose a list or grid as the default menu layout',
      bind: 'menu.view',
      defaultValue: 'list',
      options: [
        SettingOption(value: 'list', label: 'List'),
        SettingOption(value: 'grid', label: 'Grid'),
      ],
    ),
    SettingNode.page(
      id: 'by-section',
      label: 'Section Views',
      summary: 'Choose a list or grid layout for individual menu sections',
      screen: 'menu-views',
      bind: 'menu.views',
    ),
    SettingNode.page(
      id: 'hidden',
      label: 'Hidden Items',
      summary: 'Choose which menu items to hide',
      screen: 'menu-hidden',
      bind: 'menu.hidden',
    ),
    SettingNode.page(
      id: 'order',
      label: 'Order',
      summary: 'Reorder menu items',
      screen: 'menu-order',
      bind: 'menu.order',
      defaultValue: <String>[],
    ),
    SettingNode.toggle(
      id: 'remember',
      label: 'Remember Last Page',
      summary: 'Restore the last open page when returning to an app',
      bind: 'menu.remember',
      defaultValue: true,
    ),
    SettingNode.toggle(
      id: 'wrap',
      label: 'Wrap Navigation',
      summary: 'Continue from the last item to the first, and vice versa',
      bind: 'menu.wrap',
      defaultValue: false,
    ),
    SettingNode.group(
      id: 'dock',
      label: 'Dock',
      icon: 'layout-grid',
      summary: 'Customize the app switcher at the bottom of the screen',
      children: [
        SettingNode.page(
          id: 'pins',
          label: 'Pinned Apps',
          summary: 'Choose additional apps to show in the dock',
          screen: 'dock-pins',
          bind: 'dock.pins',
          defaultValue: ['/apps/files'],
        ),
        SettingNode.toggle(
          id: 'flow',
          label: 'Cover Flow',
          summary: 'Show angled app previews instead of flat previews',
          bind: 'dock.flow',
          defaultValue: true,
        ),
        SettingNode.toggle(
          id: 'at-root',
          label: 'Open Dock on Back',
          summary: 'Open the dock when pressing Back at the top of an app',
          bind: 'dock.atRoot',
          defaultValue: true,
        ),
      ],
    ),
    SettingNode.group(
      id: 'quick',
      label: 'Quick Settings',
      icon: 'sliders-horizontal',
      summary: 'Choose controls for the Quick Settings panel',
      children: [
        SettingNode.page(
          id: 'pins',
          label: 'Pinned Settings',
          summary: 'Choose and arrange controls in Quick Settings',
          screen: 'quick-pins',
          bind: 'quick.pins',
        ),
        SettingNode.toggle(
          id: 'close-after',
          label: 'Close After Change',
          summary: 'Dismiss Quick Settings after changing a setting',
          bind: 'quick.closeAfter',
          defaultValue: false,
        ),
      ],
    ),
    SettingNode.action(
      id: 'reset',
      label: 'Reset Menu',
      summary: 'Restore the default menu layout and item order',
      bind: 'menu.reset',
      danger: true,
      confirm: 'Restore the default menu layout and item order?',
      pinnable: false,
    ),
  ],
);

// ---------------------------------------------------------------------------
// Display
// ---------------------------------------------------------------------------

/// The lengths an idle wait is offered in, as milliseconds.
///
/// One list for the dim and for the sleep, because they are one clock read
/// twice: both are counted from the last thing anyone did, so a pair of
/// them is read by comparing two entries of the same list rather than by
/// working out what one means in terms of the other.
///
/// Labelled the way a length is read on a small screen: the units it
/// actually has, largest first, and nothing else.
const _idleSteps = [
  SettingOption(value: null, label: 'Never'),
  SettingOption(value: 15000, label: '15s'),
  SettingOption(value: 30000, label: '30s'),
  SettingOption(value: 60000, label: '1m'),
  SettingOption(value: 120000, label: '2m'),
  SettingOption(value: 180000, label: '3m'),
  SettingOption(value: 300000, label: '5m'),
  SettingOption(value: 600000, label: '10m'),
  SettingOption(value: 900000, label: '15m'),
  SettingOption(value: 1800000, label: '30m'),
  SettingOption(value: 3600000, label: '1h'),
  SettingOption(value: 7200000, label: '2h'),
];

const _display = SettingNode.group(
  id: 'display',
  label: 'Display',
  icon: 'sun',
  summary: 'Adjust brightness, screen timeouts, and controls while asleep',
  children: [
    SettingNode.slider(
      id: 'brightness',
      label: 'Brightness',
      summary: 'Set the screen backlight brightness',
      bind: 'screen.brightness',
      store: SettingStore.device,
      defaultValue: 80,
      min: 10,
      max: 100,
      step: 5,
      unit: '%',
      pinnedByDefault: true,
    ),
    SettingNode.divider(id: 'div-sleep'),
    SettingNode.duration(
      id: 'dim-after',
      label: 'Dim After',
      summary: 'Dim the screen after this period of inactivity',
      bind: 'sleep.dimAfter',
      defaultValue: 15000,
      options: _idleSteps,
    ),
    SettingNode.duration(
      id: 'sleep-after',
      label: 'Sleep After',
      summary: 'Turn off the screen after this period of inactivity',
      bind: 'sleep.after',
      defaultValue: 30000,
      options: _idleSteps,
    ),
    SettingNode.slider(
      id: 'dim-level',
      label: 'Dim Level',
      summary: 'Set the brightness used when the screen dims',
      bind: 'sleep.dimLevel',
      defaultValue: 50,
      min: 20,
      max: 80,
      step: 10,
      unit: '%',
      when: SettingCondition(
        path: '/settings/display/dim-after',
        value: null,
        negated: true,
      ),
    ),
  ],
);

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

const _holdSteps = [
  SettingOption(value: 300, label: '300ms'),
  SettingOption(value: 600, label: '600ms'),
  SettingOption(value: 900, label: '900ms'),
];

const _chordHoldSteps = [
  SettingOption(value: 1000, label: '1s'),
  SettingOption(value: 1500, label: '1s 500ms'),
  SettingOption(value: 2000, label: '2s'),
];

const _windowSteps = [
  SettingOption(value: 250, label: '250ms'),
  SettingOption(value: 350, label: '350ms'),
  SettingOption(value: 500, label: '500ms'),
];

const _controls = SettingNode.group(
  id: 'controls',
  label: 'Controls',
  icon: 'circle-dot',
  summary: 'Configure the wheel, buttons, shortcuts, and feedback',
  children: [
    SettingNode.group(
      id: 'wheel',
      label: 'Wheel',
      icon: 'circle-dot',
      summary: 'Adjust wheel sensitivity, acceleration, and direction',
      children: [
        SettingNode.choice(
          id: 'sensitivity',
          label: 'Sensitivity',
          summary: 'Clicks per step: Low 3, Medium 2, High 1',
          bind: 'wheel.sensitivity',
          defaultValue: 'light',
          options: [
            SettingOption(value: 'firm', label: 'Low'),
            SettingOption(value: 'standard', label: 'Medium'),
            SettingOption(value: 'light', label: 'High'),
          ],
        ),
        SettingNode.toggle(
          id: 'acceleration',
          label: 'Acceleration',
          summary:
              'Scroll faster to skip items, or for 1.5 seconds in one direction to browse letters',
          bind: 'wheel.acceleration',
          defaultValue: true,
        ),
        SettingNode.toggle(
          id: 'reverse',
          label: 'Reverse Direction',
          summary: 'Reverse the direction the wheel moves through items',
          bind: 'wheel.reverse',
          defaultValue: false,
        ),
      ],
    ),
    SettingNode.divider(id: 'div-screen-off'),
    SettingNode.toggle(
      id: 'dark-buttons',
      label: 'Playback Buttons While Screen Is Off',
      summary: 'Allow playback buttons to work while the screen is off',
      bind: 'dark.buttons',
      defaultValue: true,
    ),
    SettingNode.toggle(
      id: 'dark-wheel',
      label: 'Wheel Volume While Screen Is Off',
      summary: 'Use the wheel to adjust volume while the screen is off',
      bind: 'dark.wheel',
      defaultValue: false,
    ),
    SettingNode.toggle(
      id: 'dark-volume',
      label: 'Volume Buttons While Screen Is Off',
      summary: 'Allow volume buttons to work while the screen is off',
      bind: 'dark.volume',
      defaultValue: true,
    ),
    SettingNode.divider(id: 'div-feedback'),
    SettingNode.group(
      id: 'feedback',
      label: 'Feedback',
      icon: 'vibrate',
      summary: 'Configure vibration and sounds for wheel and button input',
      children: [
        SettingNode.toggle(
          id: 'haptics',
          label: 'Haptics',
          summary: 'Vibrate when using the wheel and buttons',
          bind: 'feedback.haptics',
          store: SettingStore.device,
          defaultValue: true,
          needs: {'device'},
        ),
        SettingNode.choice(
          id: 'haptic-feel',
          label: 'Haptic Feel',
          summary: 'Choose how soft or strong each vibration feels',
          bind: 'feedback.haptic-feel',
          defaultValue: 'standard',
          needs: {'device'},
          options: [
            SettingOption(value: 'soft', label: 'Soft'),
            SettingOption(value: 'standard', label: 'Standard'),
            SettingOption(value: 'strong', label: 'Strong'),
          ],
          when: SettingCondition(
            path: '/settings/controls/feedback/haptics',
            value: true,
          ),
        ),
        SettingNode.toggle(
          id: 'sounds',
          label: 'Click Sounds',
          summary: 'Play a sound when using the wheel and buttons',
          bind: 'feedback.sounds',
          defaultValue: true,
        ),
        SettingNode.toggle(
          id: 'speaker-only',
          label: 'Clicks Through Speaker',
          summary:
              'Use the device speaker; mute clicks with headphones plugged in',
          bind: 'feedback.speaker-only',
          defaultValue: true,
          when: SettingCondition(
            path: '/settings/controls/feedback/sounds',
            value: true,
          ),
        ),
        SettingNode.choice(
          id: 'sound-type',
          label: 'Click Sound',
          summary: 'Choose the sound for wheel turns and button presses',
          bind: 'feedback.sound-type',
          defaultValue: 'classic',
          options: [
            SettingOption(value: 'classic', label: 'Classic'),
            SettingOption(value: 'tick', label: 'Tick'),
            SettingOption(value: 'click', label: 'Click'),
            SettingOption(value: 'thump', label: 'Thump'),
          ],
          when: SettingCondition(
            path: '/settings/controls/feedback/sounds',
            value: true,
          ),
        ),
        SettingNode.slider(
          id: 'level',
          label: 'Click Sound Level',
          summary: 'Set the volume of wheel and button sounds',
          bind: 'feedback.level',
          defaultValue: 60,
          min: 10,
          max: 100,
          step: 10,
          unit: '%',
          when: SettingCondition(
            path: '/settings/controls/feedback/sounds',
            value: true,
          ),
        ),
        SettingNode.toggle(
          id: 'follow',
          label: 'Follow the Volume',
          summary: 'Match click sounds to the playback volume',
          bind: 'feedback.follow',
          defaultValue: true,
        ),
      ],
    ),
    SettingNode.group(
      id: 'buttons',
      label: 'Buttons',
      icon: 'circle',
      summary: 'Configure button actions, hold timing, and repeated presses',
      children: [
        SettingNode.duration(
          id: 'hold',
          label: 'Hold Threshold',
          summary: 'Set how long a button must be pressed to count as a hold',
          bind: 'buttons.hold',
          defaultValue: 600,
          options: _holdSteps,
        ),
        SettingNode.toggle(
          id: 'repeat',
          label: 'Repeat While Held',
          summary: 'Keep changing volume while a volume button is held',
          bind: 'buttons.repeat',
          defaultValue: true,
        ),
        SettingNode.page(
          id: 'mapping',
          label: 'Button Actions',
          summary: 'Assign actions to individual buttons',
          screen: 'button-mapping',
          bind: 'buttons.mapping',
        ),
      ],
    ),
    SettingNode.group(
      id: 'chords',
      label: 'Button Shortcuts',
      icon: 'command',
      summary: 'Configure button combinations and long-press shortcuts',
      children: [
        SettingNode.info(
          id: 'grammar',
          label: 'Supported Shortcuts',
          summary:
              'View supported holds, power-button taps, and button combinations',
          bind: 'chords.grammar',
        ),
        SettingNode.info(
          id: 'reserved',
          label: 'Reserved Button Actions',
          summary: 'View built-in button actions that cannot be reassigned',
          bind: 'chords.reserved',
        ),
        SettingNode.divider(id: 'div-timing'),
        SettingNode.duration(
          id: 'hold',
          label: 'Shortcut Hold Duration',
          summary: 'Set the hold duration for button shortcuts',
          bind: 'chords.hold',
          defaultValue: 1500,
          options: _chordHoldSteps,
        ),
        SettingNode.duration(
          id: 'window',
          label: 'Multi-Press Window',
          summary: 'Set the maximum gap between taps in a multi-press shortcut',
          bind: 'chords.window',
          defaultValue: 350,
          options: _windowSteps,
        ),
        SettingNode.divider(id: 'div-chords'),
        SettingNode.pending(
          id: 'power-dialog',
          label: 'Power Dialog',
          summary: 'Choose the shortcut that opens the power menu',
          control: SettingControl.chord,
          bind: 'chords.powerDialog',
          defaultValue: 'power/long',
        ),
        SettingNode.pending(
          id: 'screen',
          label: 'Screen Off',
          summary: 'Choose the shortcut that turns off the screen',
          control: SettingControl.chord,
          bind: 'chords.screen',
          defaultValue: 'power/single',
        ),
        SettingNode.pending(
          id: 'dock',
          label: 'Dock',
          summary: 'Double-tap Power to open or close the app switcher',
          control: SettingControl.chord,
          bind: 'chords.dock',
          defaultValue: 'power/double',
        ),
        SettingNode.pending(
          id: 'app-menu',
          label: 'App Menu',
          summary: 'Hold Menu to open the current app’s menu, when available',
          control: SettingControl.chord,
          bind: 'chords.appMenu',
          defaultValue: 'menu/long',
        ),
        SettingNode.pending(
          id: 'quick',
          label: 'Quick Settings',
          summary: 'Choose the shortcut that opens Quick Settings',
          control: SettingControl.chord,
          bind: 'chords.quick',
          defaultValue: 'select+power',
        ),
        SettingNode.pending(
          id: 'mute',
          label: 'Mute',
          summary: 'Choose the shortcut that toggles mute',
          control: SettingControl.chord,
          bind: 'chords.mute',
          defaultValue: 'volume-down/long',
        ),
        SettingNode.pending(
          id: 'shuffle',
          label: 'Shuffle',
          summary: 'Choose the shortcut that toggles shuffle',
          control: SettingControl.chord,
          bind: 'chords.shuffle',
          defaultValue: 'none',
        ),
        SettingNode.pending(
          id: 'restart',
          label: 'Force Restart',
          summary: 'Choose the shortcut that forces the player to restart',
          control: SettingControl.chord,
          bind: 'chords.restart',
          defaultValue: 'menu+power',
        ),
        SettingNode.choice(
          id: 'volume',
          label: 'Volume Panel',
          summary: 'Choose which volume controls display the volume indicator',
          bind: 'chords.volume',
          defaultValue: 'keys-and-wheel',
          layout: SettingLayout.page,
          options: [
            SettingOption(value: 'keys', label: 'Volume Keys'),
            SettingOption(value: 'keys-and-wheel', label: 'Buttons and Wheel'),
            SettingOption(value: 'manual', label: 'Never'),
          ],
        ),
        SettingNode.divider(id: 'div-all'),
        SettingNode.page(
          id: 'all',
          label: 'All Shortcuts',
          summary: 'View all button shortcuts and their assigned actions',
          screen: 'chord-list',
          bind: 'chords.all',
        ),
        SettingNode.action(
          id: 'reset',
          label: 'Reset Shortcuts',
          summary: 'Restore the default button shortcuts',
          bind: 'chords.reset',
          pinnable: false,
        ),
      ],
    ),
    _navigation,
  ],
);

// ---------------------------------------------------------------------------
// Sound
// ---------------------------------------------------------------------------

const _sound = SettingNode.group(
  id: 'sound',
  label: 'Sound',
  icon: 'volume-2',
  summary: 'Adjust volume, audio output, and sound processing',
  children: [
    SettingNode.slider(
      id: 'volume',
      label: 'Volume',
      summary: 'Set the playback volume',
      bind: 'volume.level',
      store: SettingStore.device,
      defaultValue: 50,
      min: 0,
      max: 100,
      step: 5,
      unit: '%',
      pinnedByDefault: true,
    ),
    SettingNode.stepper(
      id: 'step',
      label: 'Volume Step',
      summary: 'Set how much each volume adjustment changes the level',
      bind: 'volume.step',
      defaultValue: 5,
      min: 1,
      max: 10,
      unit: '%',
    ),
    SettingNode.slider(
      id: 'limit',
      label: 'Volume Limit',
      summary: 'Set the maximum playback volume',
      bind: 'volume.limit',
      defaultValue: 100,
      min: 20,
      max: 100,
      step: 5,
      unit: '%',
    ),
    SettingNode.toggle(
      id: 'mute-hold',
      label: 'Mute on a Long Press',
      summary: 'Mute audio by holding the volume-down button',
      bind: 'volume.muteHold',
      defaultValue: true,
    ),
    SettingNode.divider(id: 'div'),
    SettingNode.group(
      id: 'output',
      label: 'Output',
      icon: 'headphones',
      summary: 'Choose the audio output device and connection behavior',
      children: [
        SettingNode.choice(
          id: 'on-new-device',
          label: 'On New Audio Device Detected',
          summary:
              'When switching between Bluetooth and the device speaker or headphones',
          bind: 'output.onNewDevice',
          defaultValue: 'switch',
          options: [
            SettingOption(value: 'switch', label: 'Switch'),
            SettingOption(value: 'ask', label: 'Ask'),
            SettingOption(value: 'ignore', label: 'Ignore'),
          ],
        ),
        SettingNode.choice(
          id: 'route',
          label: 'Output Device',
          summary: 'Speaker, headphones, or Bluetooth',
          bind: 'output.route',
          store: SettingStore.device,
          defaultValue: 'auto',
          layout: SettingLayout.page,
          options: [
            SettingOption(
              value: 'auto',
              label: 'Automatic',
              summary: 'Use headphones when plugged in',
            ),
            SettingOption(value: 'speaker', label: 'Speaker'),
            SettingOption(value: 'headphones', label: 'Headphones'),
          ],
        ),
        SettingNode.toggle(
          id: 'pause-on-unplug',
          label: 'Pause When Unplugged',
          summary: 'Pause playback when headphones are unplugged',
          bind: 'output.pauseOnUnplug',
          defaultValue: true,
        ),
        SettingNode.toggle(
          id: 'force-speaker',
          label: 'Keep Speaker Enabled',
          summary: 'Keep the speaker active when headphones are connected',
          bind: 'output.forceSpeaker',
          defaultValue: false,
          pinnable: false,
        ),
        SettingNode.choice(
          id: 'rate',
          label: 'Sample Rate',
          summary: 'Set the audio output sample rate',
          bind: 'output.rate',
          store: SettingStore.device,
          defaultValue: 44100,
          needs: {'device'},
          keywords: ['hz', 'resample', 'quality'],
          options: [
            SettingOption(value: 44100, label: '44.1 kHz'),
            SettingOption(value: 48000, label: '48 kHz'),
          ],
        ),
      ],
    ),
    SettingNode.group(
      id: 'tone',
      label: 'Tone',
      icon: 'sliders-vertical',
      summary: 'Equalizer and stereo balance settings (not available yet)',
      children: [
        SettingNode.choice(
          id: 'eq',
          label: 'Equalizer',
          summary: 'Adjust the level of different audio frequencies',
          bind: 'tone.eq',
          store: SettingStore.device,
          defaultValue: 'off',
          layout: SettingLayout.page,
          options: [
            SettingOption(value: 'off', label: 'Off'),
            SettingOption(value: 'custom', label: 'Custom'),
          ],
        ),
        SettingNode.page(
          id: 'curve',
          label: 'Custom Curve',
          summary: 'Edit the equalizer frequency bands',
          screen: 'eq-curve',
          bind: 'tone.curve',
          when: SettingCondition(
            path: '/settings/sound/tone/eq',
            value: 'custom',
          ),
        ),
        SettingNode.slider(
          id: 'balance',
          label: 'Balance',
          summary: 'Adjust the relative volume of the left and right channels',
          bind: 'tone.balance',
          store: SettingStore.device,
          defaultValue: 0,
          min: -100,
          max: 100,
          step: 10,
          pinnable: false,
        ),
      ],
    ),
    SettingNode.choice(
      id: 'gain',
      label: 'Volume Leveling',
      summary: 'Reduce loudness differences between tracks or albums',
      bind: 'playback.gain',
      defaultValue: 'album',
      keywords: ['replaygain', 'normalize', 'loudness'],
      options: [
        SettingOption(value: 'off', label: 'Off'),
        SettingOption(value: 'track', label: 'Track'),
        SettingOption(value: 'album', label: 'Album'),
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

const _crossfadeSteps = [
  SettingOption(value: null, label: 'Off'),
  SettingOption(value: 2000, label: '2s'),
  SettingOption(value: 5000, label: '5s'),
  SettingOption(value: 10000, label: '10s'),
];

const _playback = SettingNode.group(
  id: 'playback',
  label: 'Playback',
  icon: 'play',
  summary: 'Configure playback order, transitions, and resume behavior',
  children: [
    SettingNode.choice(
      id: 'resume',
      label: 'Resume on Boot',
      summary:
          'Choose whether startup restores playback paused, playing, or not at all',
      bind: 'playback.resume',
      defaultValue: 'paused',
      options: [
        SettingOption(value: 'paused', label: 'Paused'),
        SettingOption(value: 'playing', label: 'Playing'),
        SettingOption(value: 'off', label: 'Off'),
      ],
    ),
    SettingNode.choice(
      id: 'resume-within',
      label: 'Resume Position',
      summary: 'Choose which tracks resume from their saved position',
      bind: 'playback.resumeWithin',
      defaultValue: 'long',
      layout: SettingLayout.page,
      options: [
        SettingOption(value: 'always', label: 'Always'),
        SettingOption(
          value: 'long',
          label: 'Long Tracks Only',
          summary: 'Tracks longer than 10 minutes',
        ),
        SettingOption(value: 'never', label: 'Never'),
      ],
    ),
    SettingNode.divider(id: 'div-seam'),
    SettingNode.toggle(
      id: 'gapless',
      label: 'Gapless Playback',
      summary: 'Play consecutive tracks without adding a pause',
      bind: 'playback.gapless',
      defaultValue: true,
    ),
    SettingNode.duration(
      id: 'crossfade',
      label: 'Crossfade',
      summary: 'Set the overlap duration when fading between tracks',
      bind: 'playback.crossfade',
      defaultValue: null,
      options: _crossfadeSteps,
      when: SettingCondition(path: '/settings/playback/gapless', value: false),
    ),
    SettingNode.divider(id: 'div-queue'),
    SettingNode.toggle(
      id: 'shuffle',
      label: 'Shuffle',
      summary: 'Play queued tracks in random order',
      bind: 'playback.shuffle',
      defaultValue: false,
      pinnedByDefault: true,
    ),
    SettingNode.choice(
      id: 'repeat',
      label: 'Repeat',
      summary: 'Repeat the queue, the current track, or neither',
      bind: 'playback.repeat',
      defaultValue: 'off',
      pinnedByDefault: true,
      options: [
        SettingOption(value: 'off', label: 'Off'),
        SettingOption(value: 'all', label: 'All'),
        SettingOption(value: 'one', label: 'One'),
      ],
    ),
    SettingNode.choice(
      id: 'skip',
      label: 'Skip Step',
      summary: 'Choose whether Next and Previous skip tracks or chapters',
      bind: 'playback.skip',
      defaultValue: 'chapter',
      layout: SettingLayout.page,
      options: [
        SettingOption(value: 'track', label: 'Track'),
        SettingOption(value: 'chapter', label: 'Chapter When Available'),
      ],
    ),
    SettingNode.stepper(
      id: 'seek',
      label: 'Seek Step',
      summary: 'Set the seek speed while holding Next or Previous',
      bind: 'playback.seek',
      defaultValue: 10,
      min: 5,
      max: 60,
      step: 5,
      unit: 's',
    ),
    SettingNode.toggle(
      id: 'previous-restarts',
      label: 'Previous Restarts Track',
      summary: 'Restart the current track before skipping to the previous one',
      bind: 'playback.previousRestarts',
      defaultValue: true,
    ),
    SettingNode.divider(id: 'div-log'),
    SettingNode.toggle(
      id: 'log',
      label: 'Save Play History',
      summary: 'Save play counts and last-played dates',
      bind: 'playback.log',
      defaultValue: true,
    ),
  ],
);

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------

const _library = SettingNode.group(
  id: 'library',
  label: 'Library',
  icon: 'library',
  summary: 'Manage media folders, scanning, and cached artwork',
  children: [
    SettingNode.action(
      id: 'update',
      label: 'Update Library',
      summary: 'Scan configured folders for media changes',
      icon: 'refresh-cw',
      bind: 'library.scan',
      pinnedByDefault: true,
    ),
    SettingNode.page(
      id: 'roots',
      label: 'Folders',
      icon: 'folder',
      summary: 'Choose folders to scan for each media library',
      screen: 'library-roots',
      bind: 'library.roots',
    ),
    SettingNode.page(
      id: 'order',
      label: 'Library Order',
      summary: 'Hold OK on a library, then turn the wheel to reorder it',
      icon: 'list',
      screen: 'library-order',
    ),
    SettingNode.divider(id: 'div-scan'),
    SettingNode.toggle(
      id: 'scan-on-boot',
      label: 'Scan on Startup',
      summary: 'Scan for media at startup when the library is empty',
      bind: 'library.scanOnBoot',
      defaultValue: true,
    ),
    SettingNode.choice(
      id: 'recheck',
      label: 'Check for Media Changes',
      summary: 'Choose when to check for media changes',
      bind: 'library.recheck',
      defaultValue: 'startup',
      layout: SettingLayout.page,
      options: [
        SettingOption(value: 'startup', label: 'On Startup'),
        SettingOption(value: 'card', label: 'When a Card Is Inserted'),
        SettingOption(value: 'never', label: 'Never'),
      ],
    ),
    SettingNode.toggle(
      id: 'scan-on-card',
      label: 'Scan on Card Insertion',
      summary: 'Scan for media when an SD card is inserted',
      bind: 'library.scanOnCard',
      defaultValue: true,
    ),
    SettingNode.divider(id: 'div-art'),
    SettingNode.group(
      id: 'artwork',
      label: 'Artwork',
      icon: 'image',
      summary: 'Configure artwork generation and cache storage',
      children: [
        SettingNode.toggle(
          id: 'enabled',
          label: 'Generate Artwork',
          summary: 'Generate cached thumbnails from media artwork',
          bind: 'artwork.enabled',
          defaultValue: true,
        ),
        SettingNode.choice(
          id: 'when',
          label: 'Generation Timing',
          summary: 'Choose when to generate artwork thumbnails',
          bind: 'artwork.when',
          defaultValue: 'deferred',
          layout: SettingLayout.page,
          when: SettingCondition(
            path: '/settings/library/artwork/enabled',
            value: true,
          ),
          options: [
            SettingOption(
              value: 'deferred',
              label: 'After the Scan',
              summary:
                  'Generate artwork in the background, prioritizing visible items',
            ),
            SettingOption(
              value: 'during',
              label: 'During the Scan',
              summary: 'Generate artwork while scanning; increases scan time',
            ),
          ],
        ),
        SettingNode.choice(
          id: 'cache',
          label: 'Cache Size',
          summary: 'Limit the storage used by cached artwork',
          bind: 'artwork.cache',
          defaultValue: 256,
          layout: SettingLayout.page,
          options: [
            SettingOption(value: 128, label: '128 MB'),
            SettingOption(value: 256, label: '256 MB'),
            SettingOption(value: 512, label: '512 MB'),
            SettingOption(value: null, label: 'No Limit'),
          ],
        ),
        SettingNode.action(
          id: 'clear',
          label: 'Clear Artwork Cache',
          summary: 'Delete cached artwork; regenerate it when needed',
          bind: 'artwork.clear',
          pinnable: false,
        ),
      ],
    ),
    SettingNode.page(
      id: 'kinds',
      label: 'Included File Types',
      summary: 'Choose which media file types are included in scans',
      screen: 'library-kinds',
      bind: 'library.kinds',
    ),
    SettingNode.divider(id: 'div-reset'),
    SettingNode.action(
      id: 'rebuild',
      label: 'Rebuild Library Index',
      summary: 'Recreate the library index without deleting media files',
      bind: 'library.rebuild',
      danger: true,
      confirm:
          'Rebuild the library index from the configured media folders? Media files will be kept.',
      pinnable: false,
    ),
  ],
);

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

const _connections = SettingNode.group(
  id: 'connections',
  label: 'Connections',
  icon: 'wifi',
  summary: 'Configure Wi-Fi, Bluetooth, USB, and network sharing',
  children: [
    SettingNode.group(
      id: 'wifi',
      label: 'Wi-Fi',
      summary: 'Manage Wi-Fi connections and saved networks',
      icon: 'wifi',
      needs: {'wifi'},
      children: [
        SettingNode.toggle(
          id: 'enabled',
          label: 'Wi-Fi',
          summary: 'Enable the Wi-Fi radio',
          bind: 'wifi.enabled',
          store: SettingStore.device,
          defaultValue: false,
          pinnedByDefault: true,
          oobe: 'welcome/60',
        ),
        SettingNode.page(
          id: 'network',
          label: 'Network',
          summary: 'Find and connect to a Wi-Fi network',
          screen: 'wifi-picker',
          bind: 'wifi.network',
          when: SettingCondition(
            path: '/settings/connections/wifi/enabled',
            value: true,
          ),
        ),
        SettingNode.page(
          id: 'known',
          label: 'Saved Networks',
          summary: 'Manage previously saved Wi-Fi networks',
          screen: 'wifi-known',
          bind: 'wifi.known',
        ),
        SettingNode.toggle(
          id: 'auto',
          label: 'Join Automatically',
          summary: 'Connect to saved Wi-Fi networks when available',
          bind: 'wifi.auto',
          store: SettingStore.device,
          defaultValue: true,
        ),
        SettingNode.choice(
          id: 'standby',
          label: 'Wi-Fi in Standby',
          summary: 'Choose when Wi-Fi stays enabled during standby',
          bind: 'wifi.standby',
          store: SettingStore.device,
          defaultValue: 'wakes',
          layout: SettingLayout.page,
          options: [
            SettingOption(
              value: 'wakes',
              label: 'During Background Wakes',
              summary: 'Enable Wi-Fi only for scheduled background tasks',
            ),
            SettingOption(value: 'always', label: 'Always'),
            SettingOption(value: 'never', label: 'Never'),
          ],
        ),
      ],
    ),
    SettingNode.group(
      id: 'bluetooth',
      label: 'Bluetooth',
      summary: 'Manage Bluetooth devices and audio connections',
      icon: 'bluetooth',
      needs: {'bluetooth'},
      children: [
        SettingNode.toggle(
          id: 'enabled',
          label: 'Bluetooth',
          summary: 'Enable the Bluetooth radio',
          bind: 'bluetooth.enabled',
          store: SettingStore.device,
          defaultValue: false,
          pinnedByDefault: true,
        ),
        SettingNode.page(
          id: 'devices',
          label: 'Devices',
          summary: 'Find, pair, and manage Bluetooth devices',
          screen: 'bluetooth-devices',
          bind: 'bluetooth.devices',
          when: SettingCondition(
            path: '/settings/connections/bluetooth/enabled',
            value: true,
          ),
        ),
        SettingNode.choice(
          id: 'codec',
          label: 'Codec',
          summary: 'Choose the audio codec used for Bluetooth playback',
          bind: 'bluetooth.codec',
          store: SettingStore.device,
          defaultValue: 'auto',
          layout: SettingLayout.page,
          options: [SettingOption(value: 'auto', label: 'Automatic')],
        ),
        SettingNode.toggle(
          id: 'auto',
          label: 'Reconnect Automatically',
          summary: 'Reconnect to previously paired Bluetooth devices',
          bind: 'bluetooth.auto',
          store: SettingStore.device,
          defaultValue: true,
        ),
      ],
    ),
    SettingNode.group(
      id: 'usb',
      label: 'USB',
      icon: 'usb',
      summary: 'Choose USB connection modes and sharing options',
      children: [
        SettingNode.choice(
          id: 'mode',
          label: 'Mode',
          summary:
              'Choose how the USB port connects to computers or accessories',
          bind: 'usb.mode',
          store: SettingStore.device,
          defaultValue: 'gadget',
          needs: {'device'},
          layout: SettingLayout.page,
          options: [
            SettingOption(
              value: 'charge',
              label: 'Charge Only',
              summary: 'Charge the player without a USB data connection',
            ),
            SettingOption(
              value: 'gadget',
              label: 'Gadget',
              summary:
                  'Connect the player to a computer using configured USB functions',
            ),
            SettingOption(
              value: 'storage',
              label: 'Mass Storage',
              summary:
                  'Expose the SD card as a drive on the connected computer',
            ),
            SettingOption(
              value: 'host',
              label: 'Host',
              summary:
                  'Connect USB accessories such as keyboards and storage drives',
            ),
          ],
        ),
        SettingNode.page(
          id: 'gadget',
          label: 'USB Device Functions',
          summary: 'Choose the USB functions exposed to a connected computer',
          screen: 'usb-gadget',
          bind: 'usb.gadget',
          when: SettingCondition(
            path: '/settings/connections/usb/mode',
            value: 'gadget',
          ),
        ),
        SettingNode.toggle(
          id: 'storage-unmount',
          label: 'Unmount SD Card While Shared',
          summary: 'Prevent local SD-card access while a computer uses it',
          bind: 'usb.storageUnmount',
          defaultValue: true,
          when: SettingCondition(
            path: '/settings/connections/usb/mode',
            value: 'storage',
          ),
        ),
      ],
    ),

    SettingNode.group(
      id: 'samba',
      label: 'File Sharing',
      summary: 'Configure network access to shared folders',
      icon: 'folder-open',
      children: [
        SettingNode.toggle(
          id: 'enabled',
          label: 'File Sharing',
          summary: 'Share selected folders over the network',
          bind: 'samba.enabled',
          store: SettingStore.device,
          defaultValue: false,
          keywords: ['samba', 'smb', 'network drive'],
        ),
        SettingNode.toggle(
          id: 'writable',
          label: 'Allow Writing',
          summary: 'Allow network clients to modify shared files',
          bind: 'samba.writable',
          store: SettingStore.device,
          defaultValue: true,
          when: SettingCondition(
            path: '/settings/connections/samba/enabled',
            value: true,
          ),
        ),
        SettingNode.toggle(
          id: 'auth',
          label: 'Require a Password',
          summary: 'Require a password to access shared folders',
          bind: 'samba.auth',
          store: SettingStore.device,
          defaultValue: true,
          when: SettingCondition(
            path: '/settings/connections/samba/enabled',
            value: true,
          ),
        ),
        SettingNode.pending(
          id: 'password',
          label: 'Password',
          summary: 'Set the password used for file sharing',
          control: SettingControl.text,
          store: SettingStore.secret,
          bind: 'samba.password',
          when: SettingCondition(
            path: '/settings/connections/samba/auth',
            value: true,
          ),
        ),
        SettingNode.page(
          id: 'shares',
          label: 'Shared Folders',
          summary: 'Choose which folders are available over the network',
          screen: 'samba-shares',
          bind: 'samba.shares',
        ),
      ],
    ),
    SettingNode.group(
      id: 'mpd',
      label: 'Music Server',
      summary: 'Configure network access to the music library',
      icon: 'radio',
      children: [
        SettingNode.toggle(
          id: 'enabled',
          label: 'Music Server',
          summary: 'Make the music library available to network clients',
          bind: 'mpd.enabled',
          store: SettingStore.device,
          defaultValue: false,
          keywords: ['mpd', 'remote control'],
        ),
        SettingNode.stepper(
          id: 'port',
          label: 'Port',
          summary: 'Set the network port used by the music server',
          bind: 'mpd.port',
          store: SettingStore.device,
          defaultValue: 6600,
          min: 1024,
          max: 65535,
          pinnable: false,
          when: SettingCondition(
            path: '/settings/connections/mpd/enabled',
            value: true,
          ),
        ),
        SettingNode.toggle(
          id: 'control',
          label: 'Allow Control',
          summary: 'Allow connected clients to control playback and the queue',
          bind: 'mpd.control',
          store: SettingStore.device,
          defaultValue: true,
          when: SettingCondition(
            path: '/settings/connections/mpd/enabled',
            value: true,
          ),
        ),
      ],
    ),
    SettingNode.group(
      id: 'remote',
      label: 'Remote Access',
      summary: 'Configure remote login and media-service access',
      icon: 'terminal',
      children: [
        SettingNode.toggle(
          id: 'ssh',
          label: 'SSH',
          summary: 'Keys only; no password login',
          bind: 'remote.ssh',
          store: SettingStore.device,
          defaultValue: false,
        ),
        SettingNode.toggle(
          id: 'media-port',
          label: 'Media Service Port',
          summary: 'Set the network port for the media service',
          bind: 'remote.mediaPort',
          store: SettingStore.device,
          defaultValue: false,
        ),
      ],
    ),
    SettingNode.info(
      id: 'plugins',
      label: 'Extension Services',
      summary: 'View sharing services provided by installed extensions',
      bind: 'sharing.plugins',
    ),
  ],
);

// ---------------------------------------------------------------------------
// Sharing services are included in Connections above
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Power
// ---------------------------------------------------------------------------

const _standbySleepSteps = [
  SettingOption(value: 60000, label: '1m'),
  SettingOption(value: 300000, label: '5m'),
  SettingOption(value: 900000, label: '15m'),
  SettingOption(value: null, label: 'Never'),
];

const _wakeSteps = [
  SettingOption(value: 900000, label: '15m'),
  SettingOption(value: 1800000, label: '30m'),
  SettingOption(value: 3600000, label: '1h'),
];

const _deepSteps = [
  SettingOption(value: 1800000, label: '30m'),
  SettingOption(value: 3600000, label: '1h'),
  SettingOption(value: 21600000, label: '6h'),
  SettingOption(value: null, label: 'Never'),
];

const _power = SettingNode.group(
  id: 'power',
  label: 'Power',
  icon: 'battery-charging',
  summary: 'Manage charging, standby, restart, and shutdown',
  children: [
    SettingNode.info(
      id: 'battery',
      label: 'Battery',
      summary: 'View the current battery and charging status',
      bind: 'power.battery',
    ),
    SettingNode.page(
      id: 'history',
      label: 'Battery History',
      summary: 'View recorded battery levels over time',
      screen: 'battery-history',
      bind: 'power.history',
      needs: {'device'},
    ),
    SettingNode.aliasOf(
      id: 'percent',
      label: 'Battery Percentage',
      summary: 'Show the remaining battery as a number in the status bar',
      alias: '/settings/appearance/status-bar/battery-percent',
    ),
    SettingNode.divider(id: 'div-charge'),
    SettingNode.choice(
      id: 'charge-limit',
      label: 'Charge Limit',
      summary: 'Stop charging at the selected battery percentage',
      bind: 'power.chargeLimit',
      store: SettingStore.device,
      defaultValue: 100,
      needs: {'device'},
      options: [
        SettingOption(value: 80, label: '80%'),
        SettingOption(value: 90, label: '90%'),
        SettingOption(value: 100, label: '100%'),
      ],
    ),
    SettingNode.group(
      id: 'standby',
      label: 'Standby',
      icon: 'moon',
      summary: 'Configure standby delays and scheduled background activity',
      children: [
        SettingNode.duration(
          id: 'sleep-after',
          label: 'Sleep After Screen Off',
          summary: 'Set how long after screen-off the player enters standby',
          bind: 'standby.sleepAfter',
          defaultValue: 300000,
          options: _standbySleepSteps,
        ),
        SettingNode.toggle(
          id: 'wakes',
          label: 'Background Wakes',
          summary: 'Periodically wake from standby to run background tasks',
          bind: 'standby.wakes',
          defaultValue: true,
          when: SettingCondition(
            path: '/settings/power/standby/sleep-after',
            value: null,
            negated: true,
          ),
        ),
        SettingNode.duration(
          id: 'interval',
          label: 'Wake Every',
          summary: 'Set the interval between scheduled background wakes',
          bind: 'standby.interval',
          defaultValue: 1800000,
          options: _wakeSteps,
          when: SettingCondition(
            path: '/settings/power/standby/wakes',
            value: true,
          ),
        ),
        SettingNode.page(
          id: 'tasks',
          label: 'Background Tasks',
          summary: 'Choose which tasks may run during scheduled wakes',
          screen: 'standby-tasks',
          bind: 'standby.tasks',
          when: SettingCondition(
            path: '/settings/power/standby/wakes',
            value: true,
          ),
        ),
        SettingNode.divider(id: 'div-deep'),
        SettingNode.duration(
          id: 'deep-after',
          label: 'Deep Sleep After',
          summary:
              'Set the delay before deep sleep disables radios and scheduled wakes',
          bind: 'standby.deepAfter',
          store: SettingStore.device,
          defaultValue: null,
          options: _deepSteps,
          needs: {'device'},
        ),
        SettingNode.choice(
          id: 'mode',
          label: 'Deep Sleep Mode',
          summary:
              'Choose whether deep sleep suspends or hibernates the player',
          bind: 'standby.mode',
          store: SettingStore.device,
          defaultValue: 'suspend',
          needs: {'device'},
          layout: SettingLayout.page,
          options: [
            SettingOption(
              value: 'suspend',
              label: 'Suspend',
              summary: 'Keep memory powered for a faster resume',
            ),
            SettingOption(
              value: 'hibernate',
              label: 'Hibernate',
              summary:
                  'Save memory to storage and power down; resumes more slowly',
            ),
          ],
          when: SettingCondition(
            path: '/settings/power/standby/deep-after',
            value: null,
            negated: true,
          ),
        ),
        SettingNode.info(
          id: 'wake-on',
          label: 'Wake Sources',
          summary: 'View the hardware controls that can wake the player',
          bind: 'standby.wakeOn',
          needs: {'device'},
        ),
      ],
    ),
    SettingNode.aliasOf(
      id: 'hold',
      label: 'Shortcut Hold Duration',
      summary: 'Set the hold duration for button shortcuts',
      alias: '/settings/controls/chords/hold',
    ),
    SettingNode.divider(id: 'div-off'),
    SettingNode.action(
      id: 'restart',
      label: 'Restart',
      summary: 'Restart the player',
      icon: 'rotate-cw',
      bind: 'power.restart',
      confirm: 'Restart the player?',
    ),
    SettingNode.action(
      id: 'shutdown',
      label: 'Power Off',
      summary: 'Turn off the player',
      icon: 'power',
      bind: 'power.shutdown',
      danger: true,
      confirm: 'Power the player off?',
    ),
  ],
);

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

const _storage = SettingNode.group(
  id: 'storage',
  label: 'Storage',
  icon: 'hard-drive',
  summary: 'Manage internal storage, the SD card, and backups',
  children: [
    SettingNode.page(
      id: 'data',
      label: 'Tempo Data Storage',
      summary: 'Choose Yes, No or Ask for SD card storage',
      screen: 'data-storage',
    ),
    SettingNode.page(
      id: 'usage',
      label: 'Storage Usage',
      summary: 'View used and available storage by category',
      screen: 'storage-usage',
      bind: 'storage.usage',
    ),
    SettingNode.info(
      id: 'card',
      label: 'Card',
      summary: 'View information about the inserted SD card',
      bind: 'storage.card',
    ),
    SettingNode.action(
      id: 'eject',
      label: 'Eject SD Card',
      summary: 'Unmount the SD card before removing it',
      icon: 'eject',
      bind: 'storage.eject',
    ),
    SettingNode.divider(id: 'div-files'),
    SettingNode.toggle(
      id: 'hidden',
      label: 'Show Hidden Files',
      summary: 'Include hidden files and folders in the Files app',
      bind: 'files.hidden',
      defaultValue: false,
    ),
    SettingNode.divider(id: 'div-backup'),
    SettingNode.group(
      id: 'backups',
      label: 'Backups',
      icon: 'archive',
      summary: 'Save and restore settings backups',
      children: [
        SettingNode.action(
          id: 'now',
          label: 'Back Up Settings',
          summary:
              'Save settings to the SD card, excluding passwords and other secrets',
          bind: 'backup.now',
        ),
        SettingNode.choice(
          id: 'auto',
          label: 'Backup Schedule',
          summary: 'Choose when settings backups are created',
          bind: 'backup.auto',
          defaultValue: 'weekly',
          layout: SettingLayout.page,
          options: [
            SettingOption(value: 'never', label: 'Never'),
            SettingOption(value: 'weekly', label: 'Weekly'),
            SettingOption(value: 'change', label: 'After Any Change'),
          ],
        ),
        SettingNode.page(
          id: 'restore',
          label: 'Restore',
          summary: 'Restore settings from a saved backup',
          screen: 'backup-restore',
          bind: 'backup.restore',
          danger: true,
        ),
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// Apps & Extensions
// ---------------------------------------------------------------------------

const _extensions = SettingNode.group(
  id: 'extensions',
  label: 'Apps & Extensions',
  icon: 'puzzle',
  summary: 'Manage installed apps, extensions, and their permissions',
  children: [
    SettingNode.page(
      id: 'installed',
      label: 'Installed',
      summary: 'View and manage installed apps and extensions',
      screen: 'extensions-list',
      bind: 'extensions.installed',
    ),
    SettingNode.page(
      id: 'permissions',
      label: 'Permissions',
      summary: 'Manage which device features extensions can access',
      screen: 'extensions-permissions',
      bind: 'extensions.permissions',
    ),
    SettingNode.page(
      id: 'sources',
      label: 'Sources',
      summary: 'Manage sources for downloading apps and extensions',
      screen: 'extensions-sources',
      bind: 'extensions.sources',
    ),
    SettingNode.toggle(
      id: 'auto-update',
      label: 'Update Extensions Automatically',
      summary: 'Automatically install available extension updates',
      bind: 'extensions.autoUpdate',
      defaultValue: false,
    ),
    SettingNode.toggle(
      id: 'unsigned',
      label: 'Allow Unsigned Extensions',
      summary: 'Allow extensions without a verified digital signature',
      bind: 'extensions.unsigned',
      defaultValue: false,
      needs: {'dev'},
      danger: true,
      confirm: 'Allow extensions without a verified digital signature?',
    ),
  ],
);

// ---------------------------------------------------------------------------
// Time & Language
// ---------------------------------------------------------------------------

const _time = SettingNode.group(
  id: 'time',
  label: 'Time & Language',
  icon: 'clock',
  summary: 'Configure the clock, date formats, and interface language',
  children: [
    // A page rather than a list of options in the tree: the zones are
    // read from the machine's own zone table, so what can be chosen is
    // what this rootfs actually has. It is also where Auto learns where
    // the player is - see [TimeZones] and [AppearanceMode.auto].
    SettingNode.page(
      id: 'zone',
      label: 'Time Zone',
      summary: 'Set the system time zone used by the clock and automatic theme',
      screen: 'time-zone',
      bind: 'time.zone',
      store: SettingStore.device,
      defaultValue: 'UTC',
      oobe: 'welcome/20',
      keywords: ['region', 'city', 'sunrise', 'sunset'],
    ),
    SettingNode.toggle(
      id: 'auto',
      label: 'Set Automatically',
      summary: 'Synchronize the clock with network time',
      bind: 'time.auto',
      store: SettingStore.device,
      defaultValue: true,
      needs: {'wifi'},
    ),
    SettingNode.pending(
      id: 'manual',
      label: 'Date and Time',
      summary: 'Set the date and time manually',
      control: SettingControl.time,
      bind: 'time.manual',
      store: SettingStore.device,
      when: SettingCondition(path: '/settings/system/time/auto', value: false),
    ),
    SettingNode.divider(id: 'div-format'),
    SettingNode.choice(
      id: 'hour',
      label: 'Clock Format',
      summary: 'Choose a 12-hour or 24-hour clock',
      bind: 'time.hour',
      defaultValue: 24,
      options: [
        SettingOption(value: 12, label: '12 Hour'),
        SettingOption(value: 24, label: '24 Hour'),
      ],
    ),
    SettingNode.choice(
      id: 'date',
      label: 'Date Format',
      summary: 'Choose how dates are displayed',
      bind: 'time.date',
      defaultValue: 'iso',
      layout: SettingLayout.page,
      options: [
        SettingOption(value: 'iso', label: '2026-09-03'),
        SettingOption(value: 'dmy', label: '3 Sep 2026'),
        SettingOption(value: 'mdy', label: 'Sep 3 2026'),
      ],
    ),
    SettingNode.choice(
      id: 'week',
      label: 'First Day of the Week',
      summary: 'Choose the first day shown in calendar views',
      bind: 'time.week',
      defaultValue: 'monday',
      pinnable: false,
      options: [
        SettingOption(value: 'monday', label: 'Monday'),
        SettingOption(value: 'sunday', label: 'Sunday'),
      ],
    ),
    SettingNode.divider(id: 'div-language'),
    SettingNode.choice(
      id: 'language',
      label: 'Language',
      summary:
          'Choose the interface language; only English is currently available',
      bind: 'time.language',
      defaultValue: 'en',
      layout: SettingLayout.page,
      oobe: 'welcome/10',
      options: [SettingOption(value: 'en', label: 'English')],
    ),
  ],
);

// ---------------------------------------------------------------------------
// Privacy
// ---------------------------------------------------------------------------

const _privacy = SettingNode.group(
  id: 'privacy',
  label: 'Privacy',
  icon: 'lock',
  summary: 'Lock, encryption, and reporting settings (not available yet)',
  children: [
    SettingNode.group(
      id: 'pin',
      label: 'PIN Lock',
      summary: 'Configure when a PIN is needed to unlock the player',
      icon: 'lock-keyhole',
      children: [
        SettingNode.toggle(
          id: 'enabled',
          label: 'PIN Lock',
          summary: 'Require a PIN to unlock the player',
          bind: 'pin.enabled',
          defaultValue: false,
        ),
        SettingNode.page(
          id: 'change',
          label: 'Change PIN',
          summary: 'Set a new unlock PIN',
          screen: 'pin-change',
          bind: 'pin.change',
          when: SettingCondition(
            path: '/settings/system/privacy/pin/enabled',
            value: true,
          ),
        ),
        SettingNode.choice(
          id: 'when',
          label: 'Require PIN',
          summary: 'Choose when a PIN is required to unlock the player',
          bind: 'pin.when',
          defaultValue: 'boot',
          layout: SettingLayout.page,
          when: SettingCondition(
            path: '/settings/system/privacy/pin/enabled',
            value: true,
          ),
          options: [
            SettingOption(value: 'boot', label: 'On Startup'),
            SettingOption(value: 'sleep', label: 'After Sleep'),
            SettingOption(value: 'idle', label: 'After Extended Sleep'),
          ],
        ),
        SettingNode.toggle(
          id: 'locked-keys',
          label: 'Playback Buttons While Locked',
          summary: 'Allow playback buttons to work while the player is locked',
          bind: 'pin.lockedKeys',
          defaultValue: true,
          when: SettingCondition(
            path: '/settings/system/privacy/pin/enabled',
            value: true,
          ),
        ),
      ],
    ),
    SettingNode.group(
      id: 'encryption',
      label: 'Encryption',
      icon: 'shield',
      summary:
          'Configure encryption for internal storage; excludes the SD card',
      children: [
        SettingNode.toggle(
          id: 'enabled',
          label: 'Encrypt Player Storage',
          summary: 'Encrypt files stored in internal storage',
          bind: 'encryption.enabled',
          store: SettingStore.device,
          defaultValue: false,
          danger: true,
          confirm:
              'Encrypt the player\'s storage? This rewrites it, and a '
              'forgotten passphrase cannot be recovered.',
        ),
        SettingNode.pending(
          id: 'passphrase',
          label: 'Passphrase',
          summary: 'Set the passphrase used to unlock encrypted storage',
          control: SettingControl.text,
          store: SettingStore.secret,
          bind: 'encryption.passphrase',
          when: SettingCondition(
            path: '/settings/system/privacy/encryption/enabled',
            value: true,
          ),
        ),
      ],
    ),
    SettingNode.divider(id: 'div-reports'),
    SettingNode.choice(
      id: 'crash',
      label: 'Crash Reports',
      summary:
          'Choose whether crash reports are disabled, stored locally, or sent',
      bind: 'privacy.crash',
      defaultValue: 'local',
      layout: SettingLayout.page,
      options: [
        SettingOption(value: 'off', label: 'Off'),
        SettingOption(
          value: 'local',
          label: 'Keep Locally',
          summary: 'Save crash reports on the player without uploading them',
        ),
        SettingOption(value: 'send', label: 'Send'),
      ],
    ),
    SettingNode.toggle(
      id: 'usage',
      label: 'Usage Statistics',
      summary: 'Share usage statistics',
      bind: 'privacy.usage',
      defaultValue: false,
    ),
    SettingNode.aliasOf(
      id: 'history',
      label: 'Play History',
      alias: '/settings/playback/log',
      summary: 'Save play counts and last-played dates',
    ),
    SettingNode.action(
      id: 'clear-history',
      label: 'Clear Play History',
      summary: 'Delete play counts and last-played dates',
      bind: 'privacy.clearHistory',
      danger: true,
      confirm: 'Delete all play counts and last-played dates?',
      pinnable: false,
    ),
  ],
);

// ---------------------------------------------------------------------------
// System
// ---------------------------------------------------------------------------

const _system = SettingNode.group(
  id: 'system',
  label: 'System',
  icon: 'cpu',
  summary: 'Configure time, privacy, software updates, diagnostics, and resets',
  children: [
    _time,
    _privacy,

    SettingNode.group(
      id: 'update',
      label: 'Updates',
      icon: 'refresh-cw',
      summary: 'Software update settings (not available yet)',
      children: [
        SettingNode.action(
          id: 'check',
          label: 'Check for Updates',
          summary: 'Check for available system software updates',
          icon: 'search',
          bind: 'update.check',
          needs: {'wifi'},
        ),
        SettingNode.choice(
          id: 'channel',
          label: 'Channel',
          summary: 'Choose stable, beta, or nightly software releases',
          bind: 'update.channel',
          defaultValue: 'stable',
          options: [
            SettingOption(value: 'stable', label: 'Stable'),
            SettingOption(value: 'beta', label: 'Beta'),
            SettingOption(value: 'nightly', label: 'Nightly'),
          ],
        ),
        SettingNode.toggle(
          id: 'auto-download',
          label: 'Download Automatically',
          summary: 'Download available system updates automatically',
          bind: 'update.autoDownload',
          defaultValue: true,
          when: SettingCondition(
            path: '/settings/system/update/channel',
            value: 'nightly',
            negated: true,
          ),
        ),
        SettingNode.toggle(
          id: 'auto-apply',
          label: 'Apply Automatically',
          summary:
              'Install downloaded updates while idle and connected to a charger',
          bind: 'update.autoApply',
          defaultValue: false,
        ),
        SettingNode.info(
          id: 'version',
          label: 'Installed Version',
          summary: 'View the installed system software version',
          bind: 'update.version',
        ),
      ],
    ),
    SettingNode.group(
      id: 'developer',
      label: 'Developer',
      icon: 'bug',
      summary: 'Configure debugging tools and diagnostic output',
      children: [
        SettingNode.toggle(
          id: 'enabled',
          label: 'Developer Mode',
          summary: 'Enable developer tools and debugging settings',
          bind: 'debug.enabled',
          // On while the player is being built, which is what
          // `DebugSettings.enabled` already says. It goes to false when
          // there is something to ship.
          defaultValue: true,
        ),
        SettingNode.toggle(
          id: 'full-filesystem',
          label: 'Browse Full Filesystem',
          summary:
              'Allow the Files app to browse outside the home folder and SD card',
          bind: 'files.fullFilesystem',
          defaultValue: false,
          when: SettingCondition(
            path: '/settings/system/developer/enabled',
            value: true,
          ),
          keywords: ['root', 'files', 'developer'],
        ),
        SettingNode.toggle(
          id: 'frame-counter',
          label: 'Frame Counter',
          summary: 'Show a frames-per-second counter on screen',
          bind: 'debug.frameCounter',
          defaultValue: false,
          when: SettingCondition(
            path: '/settings/system/developer/enabled',
            value: true,
          ),
        ),
        SettingNode.page(
          id: 'logs',
          label: 'Logs',
          summary: 'View system and application diagnostic logs',
          screen: 'logs',
          bind: 'debug.logs',
          when: SettingCondition(
            path: '/settings/system/developer/enabled',
            value: true,
          ),
        ),
        SettingNode.choice(
          id: 'log-level',
          label: 'Log Level',
          summary: 'Choose how much detail is written to diagnostic logs',
          bind: 'debug.logLevel',
          store: SettingStore.device,
          defaultValue: 'info',
          when: SettingCondition(
            path: '/settings/system/developer/enabled',
            value: true,
          ),
          options: [
            SettingOption(value: 'warn', label: 'Warnings'),
            SettingOption(value: 'info', label: 'Info'),
            SettingOption(value: 'debug', label: 'Debug'),
          ],
        ),
      ],
    ),
    SettingNode.divider(id: 'div-reset'),
    SettingNode.group(
      id: 'reset',
      label: 'Reset',
      icon: 'trash-2',
      summary: 'Reset settings, rebuild the library, or erase internal storage',
      children: [
        SettingNode.action(
          id: 'settings',
          label: 'Reset Settings',
          summary: 'Restore all settings to their defaults',
          bind: 'reset.settings',
          danger: true,
          confirm:
              'Restore all settings to their defaults? Your library and '
              'media files will be kept.',
        ),
        SettingNode.action(
          id: 'library',
          label: 'Reset Library',
          summary: 'Delete the library index while keeping media files',
          bind: 'reset.library',
          danger: true,
          confirm:
              'Delete the library index? Media files will be kept. '
              'The next scan will recreate the index.',
        ),
        SettingNode.action(
          id: 'device',
          label: 'Erase Everything',
          summary: 'Erase internal storage while keeping the SD card unchanged',
          bind: 'reset.device',
          danger: true,
          needs: {'device'},
          confirm:
              'Erase all internal storage, including settings, library data, '
              'logs, and files? The SD card will be kept.',
        ),
      ],
    ),
    SettingNode.page(
      id: 'about',
      label: 'About',
      icon: 'info',
      screen: 'about',
      summary: 'View device and software information',
    ),
  ],
);
