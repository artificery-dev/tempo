import 'package:flutter/foundation.dart' show immutable, listEquals;

/// How a branch shows its children.
enum MenuLayout {
  /// Rows, the wheel walking down them.
  list,

  /// A grid of glyphs, the wheel walking it the way a page is read: left
  /// to right, then the next row.
  grid;

  /// The one a stored name means, or null for no name and for a name this
  /// build has not heard of.
  static MenuLayout? named(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// One entry in the system menu: a branch with [children], or a leaf that
/// opens a [screen].
///
/// The menu is data, not widgets. A node says what it is called, where it
/// sits, and - for a leaf - which screen it opens, by *key*: the widgets
/// that answer to those keys are registered separately (see
/// `MenuScreens`), so the tree can come from a Dart literal today and a
/// JSON file or a plugin tomorrow without a screen changing. That is also
/// why every field here is a plain value: [toJson] and [MenuNode.fromJson]
/// round-trip the whole tree, and a source that rearranges or hides
/// entries only has to hand back a different tree.
@immutable
class MenuNode {
  const MenuNode({
    required this.id,
    required this.label,
    this.hint,
    this.screen,
    this.layout,
    this.children = const [],
  });

  /// One segment of the node's [path]: lower-case, stable, and unique among
  /// its siblings. This is what settings, plugins, and tests refer to; the
  /// [label] is free to change.
  final String id;

  /// What the wheel shows.
  final String label;

  /// An icon-ish hint for renderers that draw one - a Lucide icon name, an
  /// emoji, a color - or null for a plain row. Kept as a string on purpose:
  /// a tree from JSON cannot carry an [IconData].
  final String? hint;

  /// For a leaf: the key of the screen it opens. Null means the leaf has no
  /// screen yet and lands on the placeholder, which is the honest state for
  /// most of the tree today. Ignored on a branch.
  final String? screen;

  /// For a branch: how its children are shown. Ignored on a leaf.
  ///
  /// Null to follow the global list/grid setting. An explicit layout
  /// overrides that setting for this branch.
  final MenuLayout? layout;

  /// For a branch: what a list of this node shows, in order.
  final List<MenuNode> children;

  /// A node with nothing under it opens a screen; one with children opens
  /// a list of them.
  bool get isLeaf => children.isEmpty;

  /// Serializable, so a future JSON source is a drop-in: the same shape in
  /// and out.
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (hint != null) 'hint': hint,
    if (screen != null) 'screen': screen,
    if (layout != null) 'layout': layout!.name,
    if (children.isNotEmpty)
      'children': [for (final child in children) child.toJson()],
  };

  factory MenuNode.fromJson(Map<String, Object?> json) => MenuNode(
    id: json['id']! as String,
    label: json['label']! as String,
    hint: json['hint'] as String?,
    screen: json['screen'] as String?,
    layout: MenuLayout.named(json['layout']),
    children: [
      for (final child in (json['children'] as List<Object?>?) ?? const [])
        MenuNode.fromJson(child! as Map<String, Object?>),
    ],
  );

  @override
  bool operator ==(Object other) =>
      other is MenuNode &&
      other.id == id &&
      other.label == label &&
      other.hint == hint &&
      other.screen == screen &&
      other.layout == layout &&
      listEquals(other.children, children);

  @override
  int get hashCode =>
      Object.hash(id, label, hint, screen, layout, Object.hashAll(children));

  @override
  String toString() => 'MenuNode($id)';
}

/// A node, placed: the node itself and the path of ids that leads to it
/// from the root, which is what a screen shows and a test asserts on.
@immutable
class MenuLocation {
  const MenuLocation({required this.node, required this.path});

  final MenuNode node;

  /// `/settings/system/power`: every id from the root down, slash-joined.
  /// The root's own path is `/`.
  final String path;

  String get id => node.id;
  String get label => node.label;
  bool get isLeaf => node.isLeaf;

  /// The children, placed under this entry.
  List<MenuLocation> get children => [
    for (final child in node.children)
      MenuLocation(
        node: child,
        path: path == '/' ? '/${child.id}' : '$path/${child.id}',
      ),
  ];

  @override
  bool operator ==(Object other) =>
      other is MenuLocation && other.node == node && other.path == path;

  @override
  int get hashCode => Object.hash(node, path);

  @override
  String toString() => 'MenuLocation($path)';
}

/// The whole tree, from the root down, with every entry reachable by path.
class MenuTree {
  MenuTree(this.root) : _byPath = {} {
    void index(MenuLocation entry) {
      if (_byPath.containsKey(entry.path)) {
        throw StateError('menu: two entries at ${entry.path}');
      }
      _byPath[entry.path] = entry;
      entry.children.forEach(index);
    }

    index(MenuLocation(node: root, path: '/'));
  }

  final MenuNode root;
  final Map<String, MenuLocation> _byPath;

  /// The root, placed.
  MenuLocation get rootEntry => _byPath['/']!;

  /// The entry at [path], or null if there is none.
  MenuLocation? at(String path) => _byPath[path];

  /// Every entry, root first, in menu order.
  Iterable<MenuLocation> get entries => _byPath.values;

  /// Every leaf, in menu order.
  Iterable<MenuLocation> get leaves => entries.where((entry) => entry.isLeaf);
}
