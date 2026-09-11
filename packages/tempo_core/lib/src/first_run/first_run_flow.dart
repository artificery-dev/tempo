import 'dart:async';

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import '../app.dart';
import '../appearance.dart';
import '../content_surface.dart';
import '../panel_bar.dart';
import '../routes.dart';
import '../scale.dart';
import '../services/services.dart';
import '../settings/data_storage_screen.dart';
import '../settings/radio_screen.dart';
import '../settings/setting_tile.dart';
import '../settings/settings.dart';
import '../settings/settings_file.dart';
import '../settings/settings_tree.dart';
import '../text_entry/keyboard_screen.dart';
import '../time_zones.dart';
import 'first_run_state.dart';

/// The steps of first run, in the order they are asked. Some are skipped:
/// what a flasher's configuration already settled, the clock when the
/// network has it, storage when there is no card.
enum FirstRunStep {
  welcome,
  language,
  timeZone,
  wifi,
  clock,
  deviceName,
  account,
  theme,
  scale,
  storage,
  finish,
}

/// The app the player opens on until first run is done: the setup, on its
/// own, over the same services and settings the player uses, so a theme
/// chosen here is the theme the player comes up in.
class FirstRunApp extends StatefulWidget {
  const FirstRunApp({
    required this.services,
    this.state,
    this.settings,
    this.wheel,
    this.onFinished,
    super.key,
  });

  final PlayerServices services;

  /// The machine's word on first run; a test hands one in over a fake.
  final FirstRunState? state;

  /// A store handed in is a test's; the app's own is opened and persisted.
  final Settings? settings;
  final ClickWheelController? wheel;

  /// Called once the choices are written down and the machine is asked to
  /// restart; a test's way to know the flow ended.
  final VoidCallback? onFinished;

  @override
  State<FirstRunApp> createState() => _FirstRunAppState();
}

class _FirstRunAppState extends State<FirstRunApp> {
  late final FirstRunState _state = widget.state ?? FirstRunState();
  late final Settings _settings =
      widget.settings ?? Settings(tree: playerSettingsTree);
  SettingsFile? _file;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    await _state.load();
    if (widget.settings == null) {
      try {
        _file = await TempoApp.open(_settings, services: widget.services);
      } catch (error) {
        debugPrint('first run: settings could not be opened: $error');
      }
    }
    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _file?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<UiScale>(
    valueListenable: Appearance.scale,
    builder: (context, scale, _) => ValueListenableBuilder<Theme>(
      valueListenable: Appearance.theme,
      builder: (context, theme, _) => TomeApp(
        theme: theme,
        debugShowCheckedModeBanner: false,
        builder: (context, child) =>
            ClickWheelInput(controller: widget.wheel, child: child!),
        home: PlayerServicesScope(
          services: widget.services,
          child: SettingsScope(
            settings: _settings,
            child: UiScaleScope(
              scale: scale,
              child: _loaded
                  ? FirstRunFlow(
                      state: _state,
                      settings: _settings,
                      services: widget.services,
                      flush: () => _file?.saveSync(),
                      onFinished: widget.onFinished,
                    )
                  : const Center(child: BodyText('Getting ready…')),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The pages, one after another, each pushed over the last so the menu
/// button goes back a step the way it goes back a page anywhere else.
class FirstRunFlow extends StatefulWidget {
  const FirstRunFlow({
    required this.state,
    required this.settings,
    required this.services,
    this.flush,
    this.onFinished,
    super.key,
  });

  final FirstRunState state;
  final Settings settings;
  final PlayerServices services;
  final VoidCallback? flush;
  final VoidCallback? onFinished;

  @override
  State<FirstRunFlow> createState() => _FirstRunFlowState();
}

class _FirstRunFlowState extends State<FirstRunFlow> {
  final _navigator = GlobalKey<NavigatorState>();

  /// What has been chosen so far, by first-run field.
  final answers = <String, Object?>{};
  bool _wifiConnected = false;

  /// Whether the machine's clock can be trusted: asked when the clock
  /// step comes up, not before, since the answer follows the network step.
  bool _clockTrusted = false;

  List<FirstRunStep> get _steps => [
    FirstRunStep.welcome,
    if (!widget.state.has('locale')) FirstRunStep.language,
    if (!widget.state.has('timezone')) FirstRunStep.timeZone,
    if (widget.services.radios != null) FirstRunStep.wifi,
    if (!_wifiConnected && !_clockTrusted) FirstRunStep.clock,
    if (!widget.state.has('hostname')) FirstRunStep.deviceName,
    if (!(widget.state.has('username') && widget.state.has('password')))
      FirstRunStep.account,
    FirstRunStep.theme,
    FirstRunStep.scale,
    if (widget.services.dataStorage?.value.cardPresent ?? false)
      FirstRunStep.storage,
    FirstRunStep.finish,
  ];

  Future<void> _advance(FirstRunStep from) async {
    final steps = _steps;
    final index = steps.indexOf(from);
    if (index < 0 || index + 1 >= steps.length) return;
    final next = steps[index + 1];
    if (next == FirstRunStep.clock) {
      // Ask the machine now, after the network step: a connected player
      // gets its time from the network and needs no clock page.
      try {
        _clockTrusted = (await widget.state.clock()).synchronized;
      } catch (_) {
        _clockTrusted = DateTime.now().year >= 2025;
      }
      // A trusted clock drops the step from the list; go on from here.
      if (_clockTrusted || _wifiConnected) return _advance(from);
    }
    if (next == FirstRunStep.storage) {
      await _storage();
      return _advance(next);
    }
    final navigator = _navigator.currentState;
    if (navigator == null || !mounted) return;
    await navigator.push(
      PanelRoute<void>(
        settings: RouteSettings(name: 'first-run/${next.name}'),
        builder: (_) => _page(next),
      ),
    );
  }

  Widget _page(FirstRunStep step) => switch (step) {
    FirstRunStep.welcome => _WelcomePage(onNext: () => _advance(step)),
    FirstRunStep.language => _ChoicePage(
      title: 'Language',
      path: '/settings/system/time/language',
      settings: widget.settings,
      onNext: () => _advance(step),
    ),
    FirstRunStep.timeZone => _TimeZonePage(
      settings: widget.settings,
      onChosen: (zone) {
        answers['timezone'] = zone;
        _advance(step);
      },
    ),
    FirstRunStep.wifi => _WifiPage(
      services: widget.services,
      onNext: (connected) {
        _wifiConnected = connected;
        _advance(step);
      },
    ),
    FirstRunStep.clock => _ClockPage(
      state: widget.state,
      onNext: () => _advance(step),
    ),
    FirstRunStep.deviceName => _DeviceNamePage(
      initial: '${answers['hostname'] ?? 'tempo'}',
      onNext: (name) {
        answers['hostname'] = name;
        _advance(step);
      },
    ),
    FirstRunStep.account => _AccountPage(
      username: '${answers['username'] ?? ''}',
      onNext: (username, password) {
        answers['username'] = username;
        answers['password'] = password;
        _advance(step);
      },
    ),
    FirstRunStep.theme => _ChoicePage(
      title: 'Theme',
      path: '/settings/appearance/mode',
      settings: widget.settings,
      onNext: () => _advance(step),
    ),
    FirstRunStep.scale => _ChoicePage(
      title: 'Interface Size',
      path: '/settings/appearance/scale',
      settings: widget.settings,
      onNext: () => _advance(step),
    ),
    FirstRunStep.storage => const SizedBox.shrink(),
    FirstRunStep.finish => _FinishPage(
      answers: answers,
      state: widget.state,
      flush: widget.flush,
      onFinished: widget.onFinished,
    ),
  };

  /// The card question, as the player asks it when a card arrives, but
  /// here in its turn rather than over whatever was on screen.
  Future<void> _storage() async {
    final controller = widget.services.dataStorage;
    final navigator = _navigator.currentState;
    if (controller == null || navigator == null) return;
    await navigator.push(
      DialogRoute<void>(
        barrierDismissible: false,
        theme: UiScale.regular.theme(Appearance.brightness.value),
        builder: (context) => DataStoragePrompt(
          controller: controller,
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      WheelBackIntent: CallbackAction<WheelBackIntent>(
        onInvoke: (_) {
          _navigator.currentState?.maybePop();
          return null;
        },
      ),
    },
    child: Navigator(
      key: _navigator,
      onGenerateRoute: (_) => PanelRoute<void>(
        settings: const RouteSettings(name: 'first-run/welcome'),
        builder: (_) => _page(FirstRunStep.welcome),
      ),
    ),
  );
}

/// A page of rows the wheel walks and the centre throws.
class _RowsPage extends StatelessWidget {
  const _RowsPage({
    required this.title,
    required this.rows,
    required this.onActivate,
    this.lead,
    this.initialIndex = 0,
    super.key,
  });
  final String title;
  final List<Widget> rows;
  final ValueChanged<int> onActivate;
  final Widget? lead;
  final int initialIndex;

  @override
  Widget build(BuildContext context) {
    final scale = UiScale.of(context);
    final theme = ThemeProvider.of(context);
    return PanelScreen(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lead case final lead?)
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.space.x3,
                theme.space.x2,
                theme.space.x3,
                theme.space.x1,
              ),
              child: lead,
            ),
          Expanded(
            child: PanelList(
              itemExtent: SettingTile.extentOf(scale),
              extentOf: (index) => SettingTile.extentOf(
                scale,
                summary: rows[index] is SettingTile
                    ? (rows[index] as SettingTile).summary != null
                    : false,
              ),
              autofocus: true,
              initialIndex: initialIndex,
              onActivate: onActivate,
              children: rows,
            ),
          ),
        ],
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({required this.onNext});
  final VoidCallback onNext;
  @override
  Widget build(BuildContext context) => _RowsPage(
    key: const ValueKey('first-run-welcome'),
    title: 'Welcome',
    lead: const BodyText(
      'A few choices set your player up. Turn the wheel to look, press '
      'the centre to choose, and Menu to go back a step.',
    ),
    rows: const [SettingTile(title: 'Get started')],
    onActivate: (_) => onNext(),
  );
}

/// One setting's options as rows; choosing one moves the setting at once,
/// so the theme or the size shows itself as it is picked.
class _ChoicePage extends StatelessWidget {
  const _ChoicePage({
    required this.title,
    required this.path,
    required this.settings,
    required this.onNext,
  });
  final String title, path;
  final Settings settings;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final entry = settings.tree.at(path)!;
    final options = entry.node.options;
    final current = settings.value(path);
    final selected = options.indexWhere((o) => o.value == current);
    return _RowsPage(
      key: ValueKey('first-run-${entry.node.id}'),
      title: title,
      initialIndex: selected < 0 ? 0 : selected,
      rows: [
        for (final option in options)
          SettingTile(
            title: option.label,
            summary: option.summary,
            trailing: option.value == current
                ? Icon(theme.icons.confirm, size: theme.sizes.iconSmall)
                : null,
          ),
      ],
      onActivate: (index) {
        settings.set(path, options[index].value, source: SettingSource.oobe);
        onNext();
      },
    );
  }
}

/// The areas, then the places in one: the same two steps the settings
/// page takes, ending on the next step of setup instead of back where it
/// started.
class _TimeZonePage extends StatelessWidget {
  const _TimeZonePage({required this.settings, required this.onChosen});
  final Settings settings;
  final ValueChanged<String> onChosen;
  static const path = '/settings/system/time/zone';

  void _choose(String zone) {
    settings.set(path, zone, source: SettingSource.oobe);
    onChosen(zone);
  }

  @override
  Widget build(BuildContext context) {
    final areas = TimeZones.areas;
    final rows = [TimeZones.utc, ...areas];
    return _RowsPage(
      key: const ValueKey('first-run-zone'),
      title: 'Time Zone',
      lead: const BodyText(
        'Where is the player? Its clock and its sunrise follow.',
      ),
      rows: [
        for (final row in rows)
          SettingTile(
            title: row,
            summary: row == TimeZones.utc
                ? 'No place in particular'
                : '${TimeZones.inArea(row).length} places',
          ),
      ],
      onActivate: (index) {
        if (index == 0) return _choose(TimeZones.utc);
        final area = rows[index];
        final zones = TimeZones.inArea(area);
        Navigator.of(context).push(
          PanelRoute<void>(
            settings: RouteSettings(name: 'first-run/zone/$area'),
            builder: (_) => _RowsPage(
              key: ValueKey('first-run-zone-$area'),
              title: area,
              rows: [
                for (final zone in zones)
                  SettingTile(title: zone.location, summary: zone.comment),
              ],
              onActivate: (i) => _choose(zones[i].id),
            ),
          ),
        );
      },
    );
  }
}

class _WifiPage extends StatelessWidget {
  const _WifiPage({required this.services, required this.onNext});
  final PlayerServices services;
  final ValueChanged<bool> onNext;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: services.wifi,
    builder: (context, reading, _) {
      final connected = reading.status == WifiStatus.connected;
      return _RowsPage(
        key: const ValueKey('first-run-wifi'),
        title: 'Wi-Fi',
        lead: BodyText(
          connected
              ? 'Connected to ${reading.network ?? 'a network'}. The clock '
                    'sets itself from the network.'
              : 'A network sets the clock and brings updates. You can skip '
                    'this and set the clock yourself.',
        ),
        rows: [
          const SettingTile(
            title: 'Choose a network',
            summary: 'Turn Wi-Fi on and pick one',
          ),
          SettingTile(title: connected ? 'Continue' : 'Skip for now'),
        ],
        initialIndex: connected ? 1 : 0,
        onActivate: (index) async {
          if (index == 1) return onNext(connected);
          await Navigator.of(context).push(
            PanelRoute<void>(
              settings: const RouteSettings(name: 'first-run/wifi/pick'),
              builder: (_) => const RadioScreen(),
            ),
          );
        },
      );
    },
  );
}

/// Setting the clock by hand: five fields, each turned with the wheel
/// once chosen, and a row to set it.
class _ClockPage extends StatefulWidget {
  const _ClockPage({required this.state, required this.onNext});
  final FirstRunState state;
  final VoidCallback onNext;
  @override
  State<_ClockPage> createState() => _ClockPageState();
}

class _ClockPageState extends State<_ClockPage> {
  late DateTime _when = _initial();
  int? _editing;
  bool _busy = false;
  String? _problem;

  static DateTime _initial() {
    final now = DateTime.now();
    return now.year < 2025
        ? DateTime(2026, 1, 1, 12)
        : DateTime(now.year, now.month, now.day, now.hour, now.minute);
  }

  static const _fields = ['Year', 'Month', 'Day', 'Hour', 'Minute'];

  String _value(int field) => switch (field) {
    0 => '${_when.year}',
    1 => '${_when.month}'.padLeft(2, '0'),
    2 => '${_when.day}'.padLeft(2, '0'),
    3 => '${_when.hour}'.padLeft(2, '0'),
    _ => '${_when.minute}'.padLeft(2, '0'),
  };

  void _turn(int field, int by) {
    var next = switch (field) {
      0 => DateTime(_when.year + by, _when.month, 1, _when.hour, _when.minute),
      1 => DateTime(_when.year, _when.month + by, 1, _when.hour, _when.minute),
      2 => _when.add(Duration(days: by)),
      3 => _when.add(Duration(hours: by)),
      _ => _when.add(Duration(minutes: by)),
    };
    if (field <= 1) {
      final day = _when.day.clamp(
        1,
        DateTime(next.year, next.month + 1, 0).day,
      );
      next = DateTime(next.year, next.month, day, next.hour, next.minute);
    }
    if (next.year < 2020 || next.year > 2100) return;
    setState(() => _when = next);
  }

  Future<void> _set() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.state.setClock(_when);
      widget.onNext();
    } catch (error) {
      if (mounted) setState(() => _problem = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return InputCapture(
      active: _editing != null,
      debugLabel: 'ClockField',
      captures: const {WheelInput.wheel, WheelInput.select, WheelInput.menu},
      releaseOn: const {},
      onCapture: (intent) {
        final field = _editing;
        if (field == null) return;
        switch (intent) {
          case JogIntent(:final amount):
            _turn(field, amount);
          case ActivateIntent() || WheelBackIntent():
            setState(() => _editing = null);
          default:
            return;
        }
      },
      child: _RowsPage(
        key: const ValueKey('first-run-clock'),
        title: 'Date & Time',
        lead: BodyText(
          _problem ??
              'Choose a field, turn the wheel to change it, and press the '
                  'centre when it is right.',
        ),
        rows: [
          for (var field = 0; field < _fields.length; field++)
            SettingTile(
              title: _fields[field],
              trailing: DefaultTextStyle.merge(
                style: TextStyle(
                  fontWeight: _editing == field ? FontWeight.bold : null,
                  color: _editing == field ? theme.palette.primary.s500 : null,
                ),
                child: BodyText(
                  _value(field),
                  key: ValueKey('clock-${_fields[field].toLowerCase()}'),
                ),
              ),
            ),
          SettingTile(title: _busy ? 'Setting…' : 'Set the clock'),
        ],
        onActivate: (index) {
          if (index < _fields.length) {
            setState(() => _editing = index);
          } else if (!_busy) {
            _set();
          }
        },
      ),
    );
  }
}

/// The device's name, on the network and on the Bluetooth list.
class _DeviceNamePage extends StatelessWidget {
  const _DeviceNamePage({required this.initial, required this.onNext});
  final String initial;
  final ValueChanged<String> onNext;

  static final _host = RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,62}$');
  static String? validate(String text) => _host.hasMatch(text)
      ? null
      : 'Letters, digits and dashes; starting with a letter or digit';

  @override
  Widget build(BuildContext context) => _RowsPage(
    key: const ValueKey('first-run-device-name'),
    title: 'Device Name',
    lead: const BodyText(
      'What this player is called on the network and to Bluetooth.',
    ),
    rows: [SettingTile(title: 'Name', summary: initial)],
    onActivate: (_) async {
      final name = await KeyboardScreen.ask(
        context,
        title: 'Device Name',
        initial: initial,
        hint: 'A name for this player',
        maxLength: 63,
        validate: validate,
      );
      if (name != null) onNext(name);
    },
  );
}

/// The account: the name you sign in as, and its password. The name is a
/// Unix account name, since that is what it becomes.
class _AccountPage extends StatefulWidget {
  const _AccountPage({required this.username, required this.onNext});
  final String username;
  final void Function(String username, String password) onNext;
  @override
  State<_AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<_AccountPage> {
  late String _username = widget.username;
  String _password = '';
  String? _problem;

  static final _name = RegExp(r'^[a-z_][a-z0-9_-]{0,31}$');
  static String? validateName(String text) => text == 'root'
      ? 'root is taken'
      : _name.hasMatch(text)
      ? null
      : 'Lowercase letters, digits, dashes and underscores; up to 32';
  static String? validatePassword(String text) =>
      text.isEmpty ? 'A password is needed' : null;

  @override
  Widget build(BuildContext context) => _RowsPage(
    key: const ValueKey('first-run-account'),
    title: 'Your Account',
    lead: BodyText(
      _problem ??
          'The name you sign in to the player with, and its password. '
              'It is a Linux account: you can use it over SSH.',
    ),
    rows: [
      SettingTile(
        title: 'Name',
        summary: _username.isEmpty ? 'Choose a name' : _username,
      ),
      SettingTile(
        title: 'Password',
        summary: _password.isEmpty
            ? 'Choose a password'
            : '•' * _password.runes.length,
      ),
      const SettingTile(title: 'Continue'),
    ],
    onActivate: (index) async {
      switch (index) {
        case 0:
          final name = await KeyboardScreen.ask(
            context,
            title: 'Account Name',
            initial: _username,
            hint: 'lowercase, no spaces',
            maxLength: 32,
            validate: validateName,
          );
          if (name != null) setState(() => _username = name);
        case 1:
          final first = await KeyboardScreen.ask(
            context,
            title: 'Password',
            obscure: true,
            hint: 'Choose a password',
            validate: validatePassword,
          );
          if (first == null || !context.mounted) return;
          final again = await KeyboardScreen.ask(
            context,
            title: 'Password Again',
            obscure: true,
            hint: 'Type it once more',
            validate: (text) => text == first ? null : 'That is not the same',
          );
          if (again != null) setState(() => _password = again);
        default:
          if (validateName(_username) case final problem?) {
            setState(() => _problem = problem);
          } else if (validatePassword(_password) case final problem?) {
            setState(() => _problem = problem);
          } else {
            widget.onNext(_username, _password);
          }
      }
    },
  );
}

/// The last page: what will happen, and the row that makes it happen.
class _FinishPage extends StatefulWidget {
  const _FinishPage({
    required this.answers,
    required this.state,
    this.flush,
    this.onFinished,
  });
  final Map<String, Object?> answers;
  final FirstRunState state;
  final VoidCallback? flush;
  final VoidCallback? onFinished;
  @override
  State<_FinishPage> createState() => _FinishPageState();
}

class _FinishPageState extends State<_FinishPage> {
  bool _busy = false;
  String? _problem;

  Future<void> _finish() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      widget.flush?.call();
      final pending = {
        for (final entry in widget.answers.entries)
          if (entry.value != null) entry.key: entry.value,
      };
      if (widget.state.available) {
        if (pending.isNotEmpty) await widget.state.queue(pending);
        await widget.state.reboot();
      }
      widget.onFinished?.call();
    } catch (error) {
      if (mounted) {
        setState(() {
          _problem = '$error';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final answers = widget.answers;
    return _RowsPage(
      key: const ValueKey('first-run-finish'),
      title: 'All Set',
      lead: BodyText(
        _problem ??
            (_busy
                ? 'Restarting to finish setting up…'
                : 'The player restarts once to take these on.'),
      ),
      rows: [
        if (answers['hostname'] case final String name)
          SettingTile(title: 'Device name', summary: name),
        if (answers['username'] case final String name)
          SettingTile(title: 'Account', summary: name),
        if (answers['timezone'] case final String zone)
          SettingTile(title: 'Time zone', summary: zone),
        SettingTile(title: _busy ? 'Restarting…' : 'Finish and restart'),
      ],
      initialIndex: [
        answers['hostname'],
        answers['username'],
        answers['timezone'],
      ].whereType<String>().length,
      onActivate: (index) {
        final last = [
          answers['hostname'],
          answers['username'],
          answers['timezone'],
        ].whereType<String>().length;
        if (index == last && !_busy) _finish();
      },
    );
  }
}
