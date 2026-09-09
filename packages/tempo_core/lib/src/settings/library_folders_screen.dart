import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tomeui/tomeui.dart';

import '../content_surface.dart';
import '../status.dart';
import '../dock.dart';
import '../panel_bar.dart';
import '../routes.dart';
import '../scale.dart';
import '../services/services.dart';
import 'setting_tile.dart';
import 'settings.dart';

const libraryFoldersPath = '/settings/library/roots';

class LibraryFoldersScreen extends StatelessWidget {
  const LibraryFoldersScreen({super.key});

  static final sections = [...LibrarySection.values]
    ..sort((a, b) => a.label.compareTo(b.label));

  @override
  Widget build(BuildContext context) => PanelScreen(
    title: 'Library Folders',
    child: PanelList(
      itemExtent: SettingTile.extentOf(UiScale.of(context)),
      autofocus: true,
      onActivate: (index) => Navigator.of(context).push(
        PanelRoute(builder: (_) => _SectionFolders(section: sections[index])),
      ),
      children: [
        for (final section in sections)
          SettingTile(title: section.label, icon: MenuIcons.of(section.icon)),
      ],
    ),
  );
}

class _SectionFolders extends StatefulWidget {
  const _SectionFolders({required this.section});
  final LibrarySection section;
  @override
  State<_SectionFolders> createState() => _SectionFoldersState();
}

class _SectionFoldersState extends State<_SectionFolders> {
  void _save(List<String>? roots) {
    final settings = SettingsScope.of(context);
    final current = settings.value(libraryFoldersPath);
    final next = <String, Object?>{
      if (current is Map)
        for (final entry in current.entries) '${entry.key}': entry.value,
    };
    if (roots == null) {
      next.remove(widget.section.name);
    } else {
      next[widget.section.name] = roots;
    }
    settings.set(libraryFoldersPath, next);
    final service = PlayerServicesScope.of(context).library;
    if (service is MediaLibrary) service.configureFolders(next);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: PlayerServicesScope.of(context).library.status,
    builder: (context, status, _) => _content(context, status),
  );

  Widget _content(BuildContext context, LibraryStatus status) {
    final library = PlayerServicesScope.of(context).library;
    if (library is! MediaLibrary) {
      return const PanelScreen(
        title: 'Library Folders',
        child: ContentMessage(
          child: BodyText('The media library is unavailable.'),
        ),
      );
    }
    final roots = library.rootsFor(widget.section);
    final scale = UiScale.of(context);
    return PanelScreen(
      title: '${widget.section.label} Folders',
      child: PanelList(
        itemExtent: SettingTile.extentOf(scale),
        extentOf: (i) => SettingTile.extentOf(
          scale,
          summary: i >= 3 || (i == 2 && status.error != null),
        ),
        autofocus: true,
        onActivate: (index) async {
          if (index == 0) {
            final selected = await Navigator.of(context).push<String>(
              PageRouteBuilder<String>(
                pageBuilder: (_, _, _) => _FolderBrowser(
                  locations: library.locations?.call() ?? roots,
                ),
              ),
            );
            if (mounted && selected != null && !roots.contains(selected)) {
              _save([...roots, selected]);
            }
          } else if (index == 1) {
            _save(null);
          } else if (index == 2) {
            await library.scan();
          } else {
            _save([...roots]..removeAt(index - 3));
          }
        },
        children: [
          const SettingTile(title: 'Add Folder', icon: LucideIcons.folderPlus),
          const SettingTile(
            title: 'Use Default Folders',
            icon: LucideIcons.rotateCcw,
          ),
          SettingTile(
            title: status.scanning ? 'Scanning Libraries…' : 'Scan Libraries',
            summary: status.error,
            icon: LucideIcons.refreshCw,
          ),
          for (final root in roots)
            SettingTile(
              title: 'Remove ${p.basename(root)}',
              summary: root,
              icon: LucideIcons.folderMinus,
            ),
        ],
      ),
    );
  }
}

/// Folder-only navigation works with the wheel on the device and desktop.
class _FolderBrowser extends StatefulWidget {
  const _FolderBrowser({required this.locations});
  final List<String> locations;
  @override
  State<_FolderBrowser> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends State<_FolderBrowser> {
  String? _path;
  List<String> _folders = [];
  String? _error;
  bool _loading = false;

  Future<void> _open(String? path) async {
    setState(() {
      _path = path;
      _loading = true;
      _error = null;
    });
    try {
      final folders = path == null
          ? [...widget.locations]
          : [
              await for (final entry in Directory(
                path,
              ).list(followLinks: false))
                if (entry is Directory) entry.path,
            ];
      folders.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (mounted) setState(() => _folders = folders);
    } on FileSystemException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _folders = [];
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _folders = [...widget.locations];
  }

  @override
  Widget build(BuildContext context) => PanelScreen(
    title: _path == null ? 'Choose Folder' : p.basename(_path!),
    child: _loading
        ? const Center(child: Spinner(size: 18))
        : Column(
            children: [
              if (_error != null) ContentMessage(child: BodyText(_error!)),
              Expanded(
                child: PanelList(
                  key: ValueKey(_path),
                  itemExtent: SettingTile.extentOf(UiScale.of(context)),
                  autofocus: true,
                  onActivate: (index) {
                    if (_path != null && index == 0) {
                      Navigator.of(context).pop(_path);
                    } else if (_path != null && index == 1) {
                      _open(
                        widget.locations.contains(_path)
                            ? null
                            : p.dirname(_path!),
                      );
                    } else {
                      _open(_folders[index - (_path == null ? 0 : 2)]);
                    }
                  },
                  children: [
                    if (_path != null) ...[
                      const SettingTile(
                        title: 'Use This Folder',
                        icon: LucideIcons.check,
                      ),
                      const SettingTile(
                        title: 'Parent Folder',
                        icon: LucideIcons.cornerUpLeft,
                      ),
                    ],
                    for (final folder in _folders)
                      SettingTile(
                        title: p.basename(folder),
                        icon: LucideIcons.folder,
                      ),
                  ],
                ),
              ),
            ],
          ),
  );
}
