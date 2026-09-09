import 'package:tomeui/tomeui.dart';
import '../content_surface.dart';
import '../dock.dart';
import '../panel_bar.dart';
import '../scale.dart';
import '../services/services.dart';
import '../settings/setting_tile.dart';
import 'music.dart';
import 'video.dart';

class CollectionScreen extends StatelessWidget {
  const CollectionScreen({required this.section, super.key});
  final LibrarySection section;
  @override
  Widget build(BuildContext context) {
    final library = PlayerServicesScope.of(context).library;
    final shelf = library is MediaLibrary
        ? library.shelf(section)
        : NoLibrary.shared.tracks;
    return PanelScreen(
      title: section.label,
      child: ValueListenableBuilder(
        valueListenable: shelf,
        builder: (context, tracks, _) => ValueListenableBuilder(
          valueListenable: library.status,
          builder: (context, status, _) {
            final sorted = [...tracks]
              ..sort(
                (a, b) =>
                    a.title.toLowerCase().compareTo(b.title.toLowerCase()),
              );
            return Column(
              children: [
                if (status.error != null)
                  ContentMessage(child: BodyText(status.error!)),
                if (status.scanning) const CaptionText('Scanning libraries…'),
                Expanded(
                  child: sorted.isEmpty
                      ? EmptyShelf(
                          what: section.label.toLowerCase(),
                          icon: MenuIcons.of(section.icon),
                        )
                      : PanelList(
                          sectionOf: (index) => MusicShelf.sectionOf(
                            sorted[index].title,
                            ignoreArticles: false,
                          ),
                          itemExtent: SettingTile.extentOf(UiScale.of(context)),
                          autofocus: true,
                          onActivate: (index) {
                            final track = sorted[index];
                            if (library is MediaLibrary &&
                                library.isVideo(track)) {
                              playVideo(context, track);
                            } else {
                              final audio = sorted
                                  .where(
                                    (t) =>
                                        library is! MediaLibrary ||
                                        !library.isVideo(t),
                                  )
                                  .toList();
                              playFrom(context, audio, audio.indexOf(track));
                            }
                          },
                          children: [
                            for (final track in sorted)
                              SettingTile(
                                title: track.title,
                                icon:
                                    library is MediaLibrary &&
                                        library.isVideo(track)
                                    ? LucideIcons.film
                                    : MenuIcons.of(section.icon),
                              ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
