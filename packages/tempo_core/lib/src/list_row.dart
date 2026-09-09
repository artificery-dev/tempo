import 'package:tomeui/tomeui.dart';

/// One row of a wheel-driven list, as every list in the player draws
/// them: a glyph if there is one, the name, and a chevron when the row
/// leads somewhere. The menus and the file browser share it, so a row in
/// a folder reads exactly as a row in Settings does, and the list's own
/// dress - the cursor - is the same on both.
///
/// The row carries no color of its own: the list dresses the selected row
/// and the words and glyph take that dress, which is why the label is a
/// plain [BodyText] at full emphasis and the glyph an [Icon] with no color.
class ListRow extends StatelessWidget {
  const ListRow({
    required this.label,
    this.icon,
    this.chevron = false,
    this.emphasis = TextEmphasis.full,
    super.key,
  });

  final String label;

  /// A glyph before the name.
  final IconData? icon;

  /// Whether the row opens a level below it.
  final bool chevron;

  /// How loudly the name is set: a row in a trail column, behind the one
  /// being driven, steps back unless it is the one that was chosen.
  final TextEmphasis emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.space.x4),
      child: Row(
        spacing: theme.space.x2,
        children: [
          if (icon != null) Icon(icon, size: theme.sizes.iconSmall),
          Expanded(
            child: BodyText(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              emphasis: emphasis,
            ),
          ),
          if (chevron)
            Icon(theme.icons.chevronRight, size: theme.sizes.iconSmall),
        ],
      ),
    );
  }
}
