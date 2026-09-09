import 'menu_node.dart';
import 'menu_screen.dart';

/// The system menu, as data.
///
/// This is the tree the wheel walks from the home screen, laid out after
/// the plan for the system UI: the top level, the apps, the media library
/// by section, the settings down to the individual switches, and the
/// system settings. A leaf names its screen with a
/// [MenuScreens] key; the many that name none land on the placeholder,
/// which shows the leaf's path so the shape of the tree is visible on the
/// wheel before the screens exist.
///
/// A Dart literal for now. The shape is [MenuNode.toJson]'s, so a JSON
/// file, a plugin, or a user's rearrangement is a different source for
/// the same tree, not a different tree.
const MenuNode systemMenuRoot = MenuNode(
  id: 'menu',
  label: 'Menu',
  children: [
    // Labeled Home, and it is the now-playing screen: the wallpaper, the
    // clock, and - once there is a player - what is playing. Activating it
    // goes back there, the same as backing all the way out.
    MenuNode(
      id: 'home',
      label: 'Home',
      hint: 'house',
      screen: MenuScreens.home,
    ),
    MenuNode(
      id: 'apps',
      label: 'Apps',
      hint: 'layout-grid',
      children: [
        MenuNode(
          id: 'files',
          label: 'Files',
          hint: 'folder',
          screen: MenuScreens.files,
        ),
        MenuNode(
          id: 'fm-radio',
          label: 'FM Radio',
          hint: 'radio',
          screen: MenuScreens.fmRadio,
        ),
        MenuNode(id: 'store', label: 'Store', hint: 'shopping-bag'),
      ],
    ),
    MenuNode(
      id: 'library',
      label: 'Library',
      hint: 'library',
      children: [
        MenuNode(
          id: 'music',
          label: 'Music',
          hint: 'music',
          children: [
            MenuNode(id: 'playlists', label: 'Playlists', hint: 'list-music'),
            MenuNode(
              id: 'songs',
              label: 'Songs',
              hint: 'music',
              screen: MenuScreens.songs,
            ),
            MenuNode(
              id: 'albums',
              label: 'Albums',
              hint: 'disc',
              screen: MenuScreens.albums,
            ),
            MenuNode(
              id: 'artists',
              label: 'Artists',
              hint: 'mic-vocal',
              screen: MenuScreens.artists,
            ),
          ],
        ),
        MenuNode(
          id: 'podcasts',
          label: 'Podcasts',
          hint: 'podcast',
          screen: 'podcasts',
        ),
        MenuNode(
          id: 'recordings',
          label: 'Recordings',
          hint: 'mic',
          screen: 'recordings',
        ),
        MenuNode(
          id: 'audiobooks',
          label: 'Audiobooks',
          hint: 'book-audio',
          screen: 'audiobooks',
        ),
        MenuNode(id: 'movies', label: 'Movies', hint: 'film', screen: 'movies'),
        MenuNode(id: 'shows', label: 'Shows', hint: 'tv', screen: 'shows'),
      ],
    ),
    // Settings is its own tree, not a branch of this one: the items are
    // data of a different shape (a switch, a slider, a page of answers)
    // and they are in `settingsRoot`. This leaf is the way in.
    MenuNode(
      id: 'settings',
      label: 'Settings',
      hint: 'settings',
      screen: MenuScreens.settings,
    ),
  ],
);

/// [systemMenuRoot], indexed by path.
final MenuTree systemMenu = MenuTree(systemMenuRoot);
