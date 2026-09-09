import 'package:flutter/foundation.dart' show immutable, listEquals;

/// What an item in the settings tree is.
enum SettingKind {
  /// A page of items. Has children, no value.
  group,

  /// A value the user moves. Has a [SettingControl].
  setting,

  /// Does a thing when activated. No value.
  action,

  /// A reading, shown and not moved.
  info,

  /// A hand-written screen, named by key - the few pages a list cannot be.
  screen,

  /// The same setting, shown in a second place. Carries only the path of
  /// the real one.
  alias,

  /// A rule between rows.
  divider,
}

/// How a [SettingKind.setting] is moved.
enum SettingControl {
  /// A yes or a no: a switch at the trailing end of the row.
  toggle,

  /// A handful of named answers: a segmented control on the row, or a page
  /// of them - see [SettingLayout].
  choice,

  /// A number over a range: a track under the title, moved by the wheel.
  slider,

  /// A number stepped rather than swept: a reading the wheel steps.
  stepper,

  /// A length of time, which is a [choice] over lengths.
  duration,

  /// Words. No keyboard exists yet; these render disabled.
  text,

  /// A swatch.
  color,

  /// A time of day.
  time,

  /// A key and a gesture, captured by performing it.
  chord,
}

/// Where a setting's value lives.
enum SettingStore {
  /// The user's preferences file. The default.
  user,

  /// System state the player does not own outright - a backlight, a
  /// service unit. Written through something that can fail.
  device,

  /// Not persisted: back to the default on boot.
  session,

  /// A passphrase or a key. Never shown, never in a backup, never logged.
  secret,
}

/// Where a setting's options are shown: on the row, or on a page.
///
/// [auto] is the rule - two or three short labels fit a segmented control
/// on a 480-pixel panel and read at a glance, anything longer needs a page
/// - but the count is not the whole story, so an item can say. A Wi-Fi
/// setting with three saved networks in it is a list that will grow, and a
/// list that will grow belongs on a page from the start rather than
/// changing shape when a fourth is saved.
enum SettingLayout {
  auto,
  inline,
  page;

  /// Whether these labels can ride the row itself.
  static bool fitsInline(List<String> options) =>
      options.length >= 2 &&
      options.length <= 3 &&
      options.every((option) => option.length <= _longestInlineLabel) &&
      options.fold(0, (sum, option) => sum + option.length) <=
          _longestInlineRow;

  static const int _longestInlineLabel = 8;
  static const int _longestInlineRow = 20;

  /// What this layout means for [options], with [auto] resolved.
  bool resolvesInline(List<String> options) => switch (this) {
    SettingLayout.auto => fitsInline(options),
    SettingLayout.inline => true,
    SettingLayout.page => false,
  };
}

/// One answer a [SettingControl.choice] offers.
@immutable
class SettingOption {
  const SettingOption({required this.value, required this.label, this.summary});

  /// What choosing this means, and what is stored. Null is a real answer:
  /// "Never" for a duration, "No Limit" for a size.
  final Object? value;

  /// Short: this has to fit a segment, and it is what the row reads when
  /// the options are on a page.
  final String label;

  /// A line about this answer, for the page that lists them.
  final String? summary;

  Map<String, Object?> toJson() => {
    'value': value,
    'label': label,
    if (summary != null) 'summary': summary,
  };

  @override
  bool operator ==(Object other) =>
      other is SettingOption &&
      other.value == value &&
      other.label == label &&
      other.summary == summary;

  @override
  int get hashCode => Object.hash(value, label, summary);
}

/// A predicate on another setting's value: `when:` in the tree.
///
/// Gating by value is disabled-and-visible, never hidden. A row that
/// vanishes when another setting changes is a row a user goes looking for.
@immutable
class SettingCondition {
  const SettingCondition({
    required this.path,
    required this.value,
    this.negated = false,
  });

  /// The setting this one depends on, by full path.
  final String path;

  /// What that setting has to be - or, [negated], has to not be.
  final Object? value;

  final bool negated;

  /// `/settings/display/dim-after != never` and friends.
  factory SettingCondition.parse(String source) {
    final negated = source.contains('!=');
    final parts = source.split(negated ? '!=' : '==');
    if (parts.length != 2) {
      throw FormatException('settings: cannot read condition "$source"');
    }
    return SettingCondition(
      path: parts.first.trim(),
      value: _literal(parts.last.trim()),
      negated: negated,
    );
  }

  /// Whether [actual] - the current value of [path] - satisfies this.
  bool holds(Object? actual) => negated ? actual != value : actual == value;

  static Object? _literal(String source) => switch (source) {
    'true' => true,
    'false' => false,
    'null' => null,
    _ => int.tryParse(source) ?? source,
  };

  @override
  String toString() => '$path ${negated ? '!=' : '=='} $value';
}

/// One item in the settings tree: a group, a setting, an action, or one of
/// the few things that are none of those.
///
/// The tree is data, the way the menu is ([MenuNode]). An item says what it
/// is called, what kind of thing it is, what moves it, what it is worth on
/// a fresh install, and - by *key* - what code answers when it moves. The
/// code that answers is registered separately (`SettingBindings`), so the
/// tree can be a Dart literal today and a JSON file or a plugin's subtree
/// tomorrow without a binding changing.
///
/// Every field is a plain value for the same reason: [toJson] round-trips
/// the whole tree.
@immutable
class SettingNode {
  const SettingNode({
    required this.id,
    required this.label,
    this.kind = SettingKind.setting,
    this.summary,
    this.control,
    this.defaultValue,
    this.options = const [],
    this.min,
    this.max,
    this.step,
    this.unit,
    this.store = SettingStore.user,
    this.bind,
    this.screen,
    this.alias,
    this.layout = SettingLayout.auto,
    this.pinnable = true,
    this.pinnedByDefault = false,
    this.captures = false,
    this.needs = const {},
    this.when,
    this.oobe,
    this.danger = false,
    this.confirm,
    this.icon,
    this.keywords = const [],
    this.children = const [],
  });

  /// A page of items.
  const SettingNode.group({
    required this.id,
    required this.label,
    this.summary,
    this.icon,
    this.needs = const {},
    this.when,
    this.children = const [],
  }) : kind = SettingKind.group,
       control = null,
       defaultValue = null,
       options = const [],
       min = null,
       max = null,
       step = null,
       unit = null,
       store = SettingStore.user,
       bind = null,
       screen = null,
       alias = null,
       layout = SettingLayout.auto,
       pinnable = false,
       pinnedByDefault = false,
       captures = false,
       oobe = null,
       danger = false,
       confirm = null,
       keywords = const [];

  /// A yes or a no.
  const SettingNode.toggle({
    required this.id,
    required this.label,
    required bool this.defaultValue,
    this.bind,
    this.summary,
    this.icon,
    this.store = SettingStore.user,
    this.pinnable = true,
    this.pinnedByDefault = false,
    this.needs = const {},
    this.when,
    this.oobe,
    this.danger = false,
    this.confirm,
    this.keywords = const [],
  }) : kind = SettingKind.setting,
       control = SettingControl.toggle,
       options = const [],
       min = null,
       max = null,
       step = null,
       unit = null,
       screen = null,
       alias = null,
       layout = SettingLayout.auto,
       captures = false,
       children = const [];

  /// A handful of named answers.
  const SettingNode.choice({
    required this.id,
    required this.label,
    required this.defaultValue,
    required this.options,
    this.bind,
    this.summary,
    this.icon,
    this.layout = SettingLayout.auto,
    this.store = SettingStore.user,
    this.pinnable = true,
    this.pinnedByDefault = false,
    this.needs = const {},
    this.when,
    this.oobe,
    this.keywords = const [],
  }) : kind = SettingKind.setting,
       control = SettingControl.choice,
       min = null,
       max = null,
       step = null,
       unit = null,
       screen = null,
       alias = null,
       captures = false,
       danger = false,
       confirm = null,
       children = const [];

  /// A length of time: a choice over lengths, `null` for never.
  const SettingNode.duration({
    required this.id,
    required this.label,
    required this.defaultValue,
    required this.options,
    this.bind,
    this.summary,
    this.icon,
    this.layout = SettingLayout.page,
    this.store = SettingStore.user,
    this.pinnable = true,
    this.pinnedByDefault = false,
    this.needs = const {},
    this.when,
    this.keywords = const [],
  }) : kind = SettingKind.setting,
       control = SettingControl.duration,
       min = null,
       max = null,
       step = null,
       unit = null,
       screen = null,
       alias = null,
       captures = false,
       oobe = null,
       danger = false,
       confirm = null,
       children = const [];

  /// A number over a range, moved by the wheel on a track.
  const SettingNode.slider({
    required this.id,
    required this.label,
    required num this.defaultValue,
    required num this.min,
    required num this.max,
    this.step,
    this.unit,
    this.bind,
    this.summary,
    this.icon,
    this.store = SettingStore.user,
    this.pinnable = true,
    this.pinnedByDefault = false,
    this.needs = const {},
    this.when,
    this.keywords = const [],
  }) : kind = SettingKind.setting,
       control = SettingControl.slider,
       options = const [],
       screen = null,
       alias = null,
       layout = SettingLayout.auto,
       captures = true,
       oobe = null,
       danger = false,
       confirm = null,
       children = const [];

  /// A number stepped in place.
  const SettingNode.stepper({
    required this.id,
    required this.label,
    required num this.defaultValue,
    required num this.min,
    required num this.max,
    this.step = 1,
    this.unit,
    this.bind,
    this.summary,
    this.icon,
    this.store = SettingStore.user,
    this.pinnable = true,
    this.needs = const {},
    this.when,
    this.keywords = const [],
  }) : kind = SettingKind.setting,
       control = SettingControl.stepper,
       options = const [],
       screen = null,
       alias = null,
       layout = SettingLayout.auto,
       pinnedByDefault = false,
       captures = true,
       oobe = null,
       danger = false,
       confirm = null,
       children = const [];

  /// A swatch, chosen off the ramp itself.
  ///
  /// Stored as the swatch's name - `sky`, `zinc` - because a settings file
  /// holds a word, not twelve colors. An unrecognised name resolves to
  /// Tome's own default for the role rather than failing.
  const SettingNode.color({
    required this.id,
    required this.label,
    this.defaultValue,
    this.bind,
    this.summary,
    this.icon,
    this.store = SettingStore.user,
    this.needs = const {},
    this.when,
    this.keywords = const [],
    this.pinnable = true,
    this.pinnedByDefault = false,
  }) : kind = SettingKind.setting,
       control = SettingControl.color,
       options = const [],
       min = null,
       max = null,
       step = null,
       unit = null,
       screen = null,
       alias = null,
       layout = SettingLayout.auto,
       captures = false,
       oobe = null,
       danger = false,
       confirm = null,
       children = const [];

  /// A setting whose control does not exist yet - words, a time, a chord.
  /// It renders, and it is disabled until one does.
  const SettingNode.pending({
    required this.id,
    required this.label,
    required SettingControl this.control,
    this.defaultValue,
    this.bind,
    this.summary,
    this.icon,
    this.store = SettingStore.user,
    this.needs = const {},
    this.when,
    this.keywords = const [],
  }) : kind = SettingKind.setting,
       options = const [],
       min = null,
       max = null,
       step = null,
       unit = null,
       screen = null,
       alias = null,
       layout = SettingLayout.auto,
       pinnable = false,
       pinnedByDefault = false,
       captures = false,
       oobe = null,
       danger = false,
       confirm = null,
       children = const [];

  /// Does a thing when activated.
  const SettingNode.action({
    required this.id,
    required this.label,
    this.bind,
    this.summary,
    this.icon,
    this.danger = false,
    this.confirm,
    this.pinnable = true,
    this.pinnedByDefault = false,
    this.needs = const {},
    this.when,
    this.keywords = const [],
  }) : kind = SettingKind.action,
       control = null,
       defaultValue = null,
       options = const [],
       min = null,
       max = null,
       step = null,
       unit = null,
       store = SettingStore.user,
       screen = null,
       alias = null,
       layout = SettingLayout.auto,
       captures = false,
       oobe = null,
       children = const [];

  /// A page of its own, by key.
  ///
  /// A page can still hold a value - the time zone is picked on one, and
  /// is device state with a default and a place in the first-run flow -
  /// so it takes [store], [defaultValue] and [oobe] the way a choice does.
  const SettingNode.page({
    required this.id,
    required this.label,
    this.screen,
    this.bind,
    this.summary,
    this.icon,
    this.danger = false,
    this.needs = const {},
    this.when,
    this.store = SettingStore.user,
    this.defaultValue,
    this.oobe,
    this.keywords = const [],
  }) : kind = SettingKind.screen,
       control = null,
       options = const [],
       min = null,
       max = null,
       step = null,
       unit = null,
       alias = null,
       layout = SettingLayout.auto,
       pinnable = false,
       pinnedByDefault = false,
       captures = false,
       confirm = null,
       children = const [];

  /// A reading.
  const SettingNode.info({
    required this.id,
    required this.label,
    this.bind,
    this.summary,
    this.icon,
    this.needs = const {},
    this.when,
  }) : kind = SettingKind.info,
       control = null,
       defaultValue = null,
       options = const [],
       min = null,
       max = null,
       step = null,
       unit = null,
       store = SettingStore.user,
       screen = null,
       alias = null,
       layout = SettingLayout.auto,
       pinnable = false,
       pinnedByDefault = false,
       captures = false,
       oobe = null,
       danger = false,
       confirm = null,
       keywords = const [],
       children = const [];

  /// The same setting, shown in a second place.
  const SettingNode.aliasOf({
    required this.id,
    required this.label,
    required String this.alias,
    this.summary,
    this.icon,
  }) : kind = SettingKind.alias,
       control = null,
       defaultValue = null,
       options = const [],
       min = null,
       max = null,
       step = null,
       unit = null,
       store = SettingStore.user,
       bind = null,
       screen = null,
       layout = SettingLayout.auto,
       pinnable = false,
       pinnedByDefault = false,
       captures = false,
       needs = const {},
       when = null,
       oobe = null,
       danger = false,
       confirm = null,
       keywords = const [],
       children = const [];

  /// A card boundary, optionally labeled by a non-selectable section kicker.
  const SettingNode.divider({required this.id, this.label = ''})
    : kind = SettingKind.divider,
      summary = null,
      control = null,
      defaultValue = null,
      options = const [],
      min = null,
      max = null,
      step = null,
      unit = null,
      store = SettingStore.user,
      bind = null,
      screen = null,
      alias = null,
      layout = SettingLayout.auto,
      pinnable = false,
      pinnedByDefault = false,
      captures = false,
      needs = const {},
      when = null,
      oobe = null,
      danger = false,
      confirm = null,
      icon = null,
      keywords = const [],
      children = const [];

  /// One segment of the item's path: lower-kebab, stable, unique among its
  /// siblings. The path is the ancestry, and the path is what a pin, a
  /// test and a stored value refer to; the [label] is free to change.
  final String id;

  /// What the row is called.
  final String label;

  /// The line under it, saying what the setting does. One line on the row,
  /// ellipsized - keep it short.
  final String? summary;

  final SettingKind kind;

  /// For a [SettingKind.setting]: how it is moved.
  final SettingControl? control;

  /// What it is worth on a fresh install. Every setting has one.
  final Object? defaultValue;

  /// For a [SettingControl.choice] or [SettingControl.duration]: the
  /// answers, in order. Empty means they come from somewhere at runtime -
  /// output devices, time zones, the networks in range - which nothing
  /// answers yet.
  final List<SettingOption> options;

  /// For the numbers.
  final num? min;
  final num? max;
  final num? step;

  /// What the number is in: `%`, `s`.
  final String? unit;

  final SettingStore store;

  /// The key of the code that answers when this moves. Null means the
  /// value is only stored - nothing happens beyond the write. A key
  /// nobody has registered is an item that cannot do anything yet, and
  /// the screen shows it disabled rather than pretending.
  final String? bind;

  /// For a [SettingKind.screen]: the key of the page it opens.
  final String? screen;

  /// For a [SettingKind.alias]: the full path of the real setting.
  final String? alias;

  final SettingLayout layout;

  /// Whether this can be pinned to quick settings at all.
  final bool pinnable;

  /// Whether it is pinned there on a fresh install.
  final bool pinnedByDefault;

  /// Whether moving it takes the wheel ([SettingControl.slider] and
  /// [SettingControl.stepper] do).
  final bool captures;

  /// Capability keys this needs, else it is hidden: `wifi`, `bluetooth`,
  /// `card`, `device`, `dev`. Hidden, not disabled: a row that cannot
  /// exist on this hardware is not a row to hunt for.
  final Set<String> needs;

  /// A predicate on another setting, else this one is shown disabled.
  final SettingCondition? when;

  /// `stage/order` for the items a fresh install or an upgrade asks about.
  final String? oobe;

  /// Whether this destroys something. The screen confirms with [confirm].
  final bool danger;
  final String? confirm;

  /// A Lucide icon name, as [MenuNode.hint] is.
  final String? icon;

  /// Extra words a search should match.
  final List<String> keywords;

  final List<SettingNode> children;

  bool get isGroup => kind == SettingKind.group;
  bool get isLeaf => children.isEmpty;

  /// Whether this item holds a value at all.
  bool get holdsValue =>
      kind == SettingKind.setting ||
      (kind == SettingKind.screen && defaultValue != null);

  /// The labels of its options, for [SettingLayout.resolvesInline].
  List<String> get optionLabels => [for (final option in options) option.label];

  Map<String, Object?> toJson() => {
    'id': id,
    if (label.isNotEmpty) 'label': label,
    'kind': kind.name,
    if (summary != null) 'summary': summary,
    if (control != null) 'control': control!.name,
    if (defaultValue != null) 'default': defaultValue,
    if (options.isNotEmpty)
      'options': [for (final option in options) option.toJson()],
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (step != null) 'step': step,
    if (unit != null) 'unit': unit,
    if (store != SettingStore.user) 'store': store.name,
    if (bind != null) 'bind': bind,
    if (screen != null) 'screen': screen,
    if (alias != null) 'alias': alias,
    if (layout != SettingLayout.auto) 'layout': layout.name,
    if (!pinnable) 'pin': 'no',
    if (pinnedByDefault) 'pin': 'default',
    if (captures) 'wheel': 'capture',
    if (needs.isNotEmpty) 'needs': needs.toList(),
    if (when != null) 'when': when.toString(),
    if (oobe != null) 'oobe': oobe,
    if (danger) 'danger': true,
    if (confirm != null) 'confirm': confirm,
    if (icon != null) 'icon': icon,
    if (keywords.isNotEmpty) 'keywords': keywords,
    if (children.isNotEmpty)
      'children': [for (final child in children) child.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is SettingNode &&
      other.id == id &&
      other.label == label &&
      other.kind == kind &&
      other.control == control &&
      other.defaultValue == defaultValue &&
      listEquals(other.options, options) &&
      other.bind == bind &&
      other.alias == alias &&
      listEquals(other.children, children);

  @override
  int get hashCode => Object.hash(
    id,
    label,
    kind,
    control,
    defaultValue,
    Object.hashAll(options),
    bind,
    alias,
    Object.hashAll(children),
  );

  @override
  String toString() => 'SettingNode($id)';
}

/// An item, placed: the node and the path that leads to it.
@immutable
class SettingLocation {
  const SettingLocation({required this.node, required this.path});

  final SettingNode node;

  /// `/settings/display/sleep-after`: every id from the root down.
  final String path;

  String get id => node.id;
  String get label => node.label;
  SettingKind get kind => node.kind;

  List<SettingLocation> get children => [
    for (final child in node.children)
      SettingLocation(node: child, path: '$path/${child.id}'),
  ];

  @override
  bool operator ==(Object other) =>
      other is SettingLocation && other.path == path && other.node == node;

  @override
  int get hashCode => Object.hash(node, path);

  @override
  String toString() => 'SettingLocation($path)';
}

/// The settings tree, from the root down, with every item reachable by
/// path - the shape [MenuTree] has, for the same reasons.
class SettingsTree {
  SettingsTree(this.root, {this.rootPath = '/settings'}) : _byPath = {} {
    void index(SettingLocation entry) {
      if (_byPath.containsKey(entry.path)) {
        throw StateError('settings: two items at ${entry.path}');
      }
      _byPath[entry.path] = entry;
      entry.children.forEach(index);
    }

    index(SettingLocation(node: root, path: rootPath));
  }

  final SettingNode root;
  final String rootPath;

  final Map<String, SettingLocation> _byPath;

  SettingLocation get rootEntry => _byPath[rootPath]!;

  SettingLocation? at(String path) => _byPath[path];

  /// Every item, root first, in tree order.
  Iterable<SettingLocation> get entries => _byPath.values;

  /// Every item that holds a value.
  Iterable<SettingLocation> get settings =>
      entries.where((entry) => entry.node.holdsValue);

  /// What every setting is worth on a fresh install, by path.
  Map<String, Object?> get defaults => {
    for (final entry in settings) entry.path: entry.node.defaultValue,
  };

  /// The paths pinned to quick settings on a fresh install, in tree order.
  List<String> get pinnedByDefault => [
    for (final entry in entries)
      if (entry.node.pinnedByDefault) entry.path,
  ];

  /// What an [SettingKind.alias] points at, or the item itself.
  SettingLocation resolve(SettingLocation entry) {
    final alias = entry.node.alias;
    if (entry.kind != SettingKind.alias || alias == null) return entry;
    return at(alias) ?? entry;
  }
}
