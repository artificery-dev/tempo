import 'dart:async';

import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';

import 'scale.dart';

/// A small dialog menu at its full height. The dialog route owns scrolling,
/// so moving the selection reveals the row along with the surrounding card.
class DialogList extends StatefulWidget {
  const DialogList({
    required this.children,
    required this.onActivate,
    super.key,
  });
  final List<Widget> children;
  final ValueChanged<int> onActivate;

  @override
  State<DialogList> createState() => _DialogListState();
}

class _DialogListState extends State<DialogList> {
  final _rows = <GlobalKey>[];
  int _selected = 0;

  void _reveal(int index) {
    final forward = index > _selected;
    _selected = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selected != index || index >= _rows.length) return;
      final scroll = Scrollable.maybeOf(context);
      if (scroll == null) return;
      final motion = ThemeProvider.of(context).motion;
      if (index == 0 || index == _rows.length - 1) {
        unawaited(
          scroll.position.animateTo(
            index == 0 ? 0 : scroll.position.maxScrollExtent,
            duration: motion.standard,
            curve: motion.move,
          ),
        );
      } else if (_rows[index].currentContext case final row?) {
        unawaited(
          Scrollable.ensureVisible(
            row,
            duration: motion.standard,
            curve: motion.move,
            alignmentPolicy: forward
                ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
                : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    while (_rows.length < widget.children.length) {
      _rows.add(GlobalKey());
    }
    if (_rows.length > widget.children.length) {
      _rows.removeRange(widget.children.length, _rows.length);
    }
    final extent = UiScale.of(context).rowExtent;
    return SizedBox(
      height: extent * widget.children.length,
      child: WheelList(
        autofocus: true,
        itemExtent: extent,
        scrollPhysics: const NeverScrollableScrollPhysics(),
        onSelectionChanged: _reveal,
        onActivate: widget.onActivate,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            KeyedSubtree(key: _rows[i], child: widget.children[i]),
        ],
      ),
    );
  }
}
