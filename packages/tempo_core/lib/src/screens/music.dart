import 'dart:async';

import 'package:tomeui/tomeui.dart';

import '../content_surface.dart';
import '../dock.dart';
import '../list_row.dart';
import '../menu/menu.dart';
import '../panel_bar.dart';
import '../routes.dart';
import '../scale.dart';
import '../services/services.dart';
import '../services/video_playback.dart';
import '../status.dart';

/// Play [queue] from [index] and go home, where now playing is - the
/// click wheel's oldest move. The Library app keeps its place in the
/// stack for when menu comes back to it.
void playFrom(BuildContext context, List<TrackSummary> queue, int index) {
  final services = PlayerServicesScope.of(context);
  VideoPlayback.active?.dispose();
  unawaited(
    FmRadioSession.stopActive().then(
      (_) => services.playback.play(queue, index: index),
    ),
  );
  final home = systemMenu.at('/home');
  if (home != null) MenuDock.select(home);
}

/// How far around the selection a shelf asks for pictures: the rows in
/// view below it and a few above, so the queue draws what the wheel is
/// about to show.
const prefetchBelow = 8;
const prefetchAbove = 3;

/// Tell the library which files the wheel is looking at, in the order it
/// will reach them: the selection, the rows below, then the rows above.
void prefetchAround(LibraryService library, List<int> fileIds, int index) {
  if (fileIds.isEmpty) return;
  final at = index.clamp(0, fileIds.length - 1);
  final wanted = <int>[
    for (var i = at; i <= at + prefetchBelow && i < fileIds.length; i++)
      fileIds[i],
    for (var i = at - 1; i >= at - prefetchAbove && i >= 0; i--) fileIds[i],
  ];
  unawaited(library.prefetch(wanted));
}

/// One track in a list: the title, and beside it - stepped back - who it
/// is by, for a list that mixes artists. One line, at every list's row
/// height; the album's own list leaves the artist out, since the album
/// already said.
class TrackRow extends StatelessWidget {
  const TrackRow({required this.track, this.showArtist = true, super.key});

  final TrackSummary track;
  final bool showArtist;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final artist = showArtist ? track.artist : null;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.space.x4),
      child: Row(
        spacing: theme.space.x2,
        children: [
          Expanded(
            child: BodyText(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (artist != null && artist.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 96),
              child: CaptionText(
                artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                emphasis: TextEmphasis.secondary,
              ),
            ),
        ],
      ),
    );
  }
}

/// What a shelf shows when there is nothing on it: why, and the way to
/// fill it.
class EmptyShelf extends StatelessWidget {
  const EmptyShelf({
    required this.what,
    this.icon = LucideIcons.music,
    super.key,
  });

  /// What would be listed here: "songs", "albums".
  final String what;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return ContentMessage(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: theme.sizes.iconLarge),
          SizedBox(height: theme.space.x2),
          CaptionText('no $what yet'),
          CaptionText(
            'Manage folders in Settings → Library',
            emphasis: TextEmphasis.secondary,
          ),
        ],
      ),
    );
  }
}

/// A shelf: a wheel-driven list built from the library's tracks, rebuilt
/// as the library changes under it, and empty with a word when it is.
class _Shelf<T> extends StatelessWidget {
  const _Shelf({
    required this.title,
    required this.what,
    required this.shelve,
    required this.row,
    required this.fileIdOf,
    required this.nameOf,
    required this.onActivate,
    super.key,
  });

  final String title;
  final String what;
  final String Function(T entry) nameOf;

  /// The tracks, sorted and grouped into the shelf's entries.
  final List<T> Function(List<TrackSummary> tracks) shelve;
  final Widget Function(T entry) row;
  final void Function(BuildContext context, List<T> entries, int index)
  onActivate;

  /// The file whose picture stands for an entry.
  final int Function(T entry) fileIdOf;

  @override
  Widget build(BuildContext context) {
    final library = PlayerServicesScope.of(context).library;
    return PanelScreen(
      title: title,
      child: ValueListenableBuilder(
        valueListenable: library.tracks,
        builder: (context, tracks, _) {
          final entries = shelve(tracks);
          if (entries.isEmpty) return EmptyShelf(what: what);
          final fileIds = [for (final entry in entries) fileIdOf(entry)];
          return PanelList(
            sectionOf: (index) => MusicShelf.sectionOf(nameOf(entries[index])),
            itemExtent: UiScale.of(context).rowExtent,
            autofocus: true,
            onActivate: (index) => onActivate(context, entries, index),
            onSelectionChanged: (index) =>
                prefetchAround(library, fileIds, index),
            children: [for (final entry in entries) row(entry)],
          );
        },
      ),
    );
  }
}

/// Every song, by title. The center button plays the list from there.
class SongsScreen extends StatelessWidget {
  const SongsScreen({super.key});

  static Route<void> route() => PanelRoute(
    settings: const RouteSettings(name: '/library/music/songs'),
    builder: (_) => const SongsScreen(),
  );

  @override
  Widget build(BuildContext context) => _Shelf<TrackSummary>(
    key: const Key('SongsScreen'),
    title: 'Songs',
    what: 'songs',
    shelve: MusicShelf.songs,
    nameOf: (track) => track.title,
    row: (track) => TrackRow(track: track),
    fileIdOf: (track) => track.fileId,
    onActivate: playFrom,
  );
}

/// Every album, by title; each opens onto its tracks.
class AlbumsScreen extends StatelessWidget {
  const AlbumsScreen({super.key});

  @override
  Widget build(BuildContext context) => _Shelf<AlbumShelf>(
    key: const Key('AlbumsScreen'),
    title: 'Albums',
    what: 'albums',
    shelve: MusicShelf.albums,
    nameOf: (album) => album.title,
    row: (album) => ListRow(label: album.title, chevron: true),
    fileIdOf: (album) => album.tracks.first.fileId,
    onActivate: (context, albums, index) =>
        Navigator.of(context).push(AlbumScreen.route(albums[index])),
  );
}

/// One album: its tracks in playing order. The center button plays the
/// album from the chosen track.
class AlbumScreen extends StatelessWidget {
  const AlbumScreen({required this.album, super.key});

  final AlbumShelf album;

  static Route<void> route(AlbumShelf album) => PanelRoute(
    settings: RouteSettings(name: '/library/music/albums/${album.title}'),
    builder: (_) => AlbumScreen(album: album),
  );

  @override
  Widget build(BuildContext context) {
    final tracks = album.tracks;
    final library = PlayerServicesScope.of(context).library;
    final fileIds = [for (final track in tracks) track.fileId];
    return PanelScreen(
      title: album.title,
      child: PanelList(
        itemExtent: UiScale.of(context).rowExtent,
        autofocus: true,
        onActivate: (index) => playFrom(context, tracks, index),
        onSelectionChanged: (index) => prefetchAround(library, fileIds, index),
        children: [
          for (final track in tracks) TrackRow(track: track, showArtist: false),
        ],
      ),
    );
  }
}

/// Every artist, by name; each opens onto their albums.
class ArtistsScreen extends StatelessWidget {
  const ArtistsScreen({super.key});

  @override
  Widget build(BuildContext context) => _Shelf<ArtistShelf>(
    key: const Key('ArtistsScreen'),
    title: 'Artists',
    what: 'artists',
    shelve: MusicShelf.artists,
    nameOf: (artist) => artist.name,
    row: (artist) => ListRow(label: artist.name, chevron: true),
    fileIdOf: (artist) => artist.tracks.first.fileId,
    onActivate: (context, artists, index) =>
        Navigator.of(context).push(ArtistScreen.route(artists[index])),
  );
}

/// One artist: All Songs first, then their albums by year.
class ArtistScreen extends StatelessWidget {
  const ArtistScreen({required this.artist, super.key});

  final ArtistShelf artist;

  static Route<void> route(ArtistShelf artist) => PanelRoute(
    settings: RouteSettings(name: '/library/music/artists/${artist.name}'),
    builder: (_) => ArtistScreen(artist: artist),
  );

  @override
  Widget build(BuildContext context) {
    final albums = artist.albums;
    return PanelScreen(
      title: artist.name,
      child: PanelList(
        itemExtent: UiScale.of(context).rowExtent,
        autofocus: true,
        onActivate: (index) => index == 0
            ? playFrom(context, artist.tracks, 0)
            : Navigator.of(context).push(AlbumScreen.route(albums[index - 1])),
        children: [
          const ListRow(label: 'All Songs', icon: LucideIcons.play),
          for (final album in albums)
            ListRow(label: album.title, chevron: true),
        ],
      ),
    );
  }
}

/// Update Library: what the library holds and what the last update did,
/// and the center button to run another. The counters move while a scan
/// does.
class LibraryUpdateScreen extends StatelessWidget {
  const LibraryUpdateScreen({super.key});

  static const scanKey = Key('LibraryUpdateScreen.scan');

  @override
  Widget build(BuildContext context) {
    final services = PlayerServicesScope.of(context);
    final library = services.library;
    final theme = ThemeProvider.of(context);

    return PanelScreen(
      title: 'Update Library',
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              unawaited(library.scan());
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          debugLabel: 'LibraryUpdateScreen',
          child: ValueListenableBuilder(
            valueListenable: library.status,
            builder: (context, status, _) => ValueListenableBuilder(
              valueListenable: library.tracks,
              builder: (context, tracks, _) => ContentMessage(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (status.scanning)
                      Spinner(size: theme.sizes.iconLarge)
                    else
                      Icon(LucideIcons.refreshCw, size: theme.sizes.iconLarge),
                    SizedBox(height: theme.space.x2),
                    BodyText('${tracks.length} songs'),
                    CaptionText(
                      _line(status),
                      emphasis: TextEmphasis.secondary,
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: theme.space.x2),
                    CaptionText(
                      status.scanning
                          ? 'updating...'
                          : status.ready
                          ? 'press the center button to update'
                          : 'opening...',
                      key: scanKey,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// What the last (or current) scan has to say for itself.
  static String _line(LibraryStatus status) {
    final error = status.error;
    if (error != null) return error;
    final scan = status.scan;
    if (scan == null) return 'never updated';
    return switch (scan.state) {
      ScanState.idle => 'never updated',
      ScanState.walking || ScanState.discovering => 'looking for files...',
      ScanState.extracting || ScanState.finishing =>
        scan.changed == 0
            ? 'nothing new, looking over ${scan.seen} files'
            : '${LibraryFooter.countOf(scan)} new or changed files',
      ScanState.done =>
        '${scan.added} added, ${scan.updated} updated, '
            '${scan.missing} missing',
      ScanState.failed => 'failed: ${scan.errors.firstOrNull?.message ?? ''}',
      ScanState.cancelled => 'stopped',
    };
  }
}
