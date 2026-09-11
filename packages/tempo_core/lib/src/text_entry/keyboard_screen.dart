import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';
import '../panel_bar.dart';
import '../routes.dart';

/// The keys of one page of the keyboard, row by row, and the row of
/// controls under them that every page shares.
///
/// Public so that a test can find a key by name and count the detents to
/// it: the wheel walks the keys in reading order, left to right along a
/// row and down to the next, wrapping at the ends.
abstract final class KeyboardLayout {
  static const lower = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  static const upper = ['QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM'];
  static const symbols = [
    '1234567890',
    '!@#\$%^&*()',
    '-_=+[]{}\\|',
    ';:\'",.<>/?~`',
  ];

  /// The controls, by their key names.
  static const shift = 'shift', more = 'more', space = 'space';
  static const delete = 'delete', cancel = 'cancel', done = 'done';
  static const controls = [shift, more, space, delete, cancel, done];

  /// Every key of a page in reading order: the characters, then the
  /// controls.
  static List<String> keys(KeyboardPage page) => [
    for (final row in rowsOf(page)) ...row.split(''),
    ...controls,
  ];

  static List<String> rowsOf(KeyboardPage page) => switch (page) {
    KeyboardPage.lower => lower,
    KeyboardPage.upper => upper,
    KeyboardPage.symbols => symbols,
  };
}

enum KeyboardPage { lower, upper, symbols }

/// Typing with a click wheel: the text so far above, the keys below, the
/// wheel walking them in reading order and the face buttons stepping in
/// the four directions. The centre presses the lit key; Done hands the
/// text back and Cancel hands back nothing. TASKS.md calls this the
/// Keyboard input.
class KeyboardScreen extends StatefulWidget {
  const KeyboardScreen({
    required this.title,
    this.initial = '',
    this.hint,
    this.obscure = false,
    this.maxLength = 63,
    this.validate,
    super.key,
  });

  final String title;
  final String initial;

  /// A line under the text saying what is wanted, until there is text.
  final String? hint;

  /// Show dots for a password.
  final bool obscure;
  final int maxLength;

  /// Why the text cannot be accepted yet, or null when it can. Done stays
  /// put and shows the reason.
  final String? Function(String text)? validate;

  /// Opens the keyboard on its own page and returns the text, or null when
  /// cancelled.
  static Future<String?> ask(
    BuildContext context, {
    required String title,
    String initial = '',
    String? hint,
    bool obscure = false,
    int maxLength = 63,
    String? Function(String text)? validate,
  }) => Navigator.of(context).push<String?>(
    PanelRoute<String?>(
      settings: RouteSettings(name: 'keyboard/$title'),
      builder: (_) => KeyboardScreen(
        title: title,
        initial: initial,
        hint: hint,
        obscure: obscure,
        maxLength: maxLength,
        validate: validate,
      ),
    ),
  );

  @override
  State<KeyboardScreen> createState() => _KeyboardScreenState();
}

class _KeyboardScreenState extends State<KeyboardScreen> {
  late String _text = widget.initial;
  KeyboardPage _page = KeyboardPage.lower;
  int _index = 0;
  String? _problem;

  List<String> get _keys => KeyboardLayout.keys(_page);
  List<String> get _rows => KeyboardLayout.rowsOf(_page);

  /// (row, column) of a key index; the controls are the last row.
  (int, int) _place(int index) {
    var start = 0;
    for (var row = 0; row < _rows.length; row++) {
      if (index < start + _rows[row].length) return (row, index - start);
      start += _rows[row].length;
    }
    return (_rows.length, index - start);
  }

  int _indexOf(int row, int column) {
    var start = 0;
    for (var r = 0; r < row; r++) {
      start += r < _rows.length ? _rows[r].length : 0;
    }
    final length = row < _rows.length
        ? _rows[row].length
        : KeyboardLayout.controls.length;
    return start + column.clamp(0, length - 1);
  }

  void _move(int by) => setState(() {
    _index = (_index + by) % _keys.length;
    if (_index < 0) _index += _keys.length;
  });

  void _step(int rows, int columns) => setState(() {
    final (row, column) = _place(_index);
    final rowCount = _rows.length + 1;
    final nextRow = (row + rows + rowCount) % rowCount;
    final length = nextRow < _rows.length
        ? _rows[nextRow].length
        : KeyboardLayout.controls.length;
    final nextColumn = (column + columns + length) % length;
    _index = _indexOf(nextRow, nextColumn);
  });

  void _press() {
    final key = _keys[_index];
    setState(() {
      _problem = null;
      switch (key) {
        case KeyboardLayout.shift:
          _page = _page == KeyboardPage.upper
              ? KeyboardPage.lower
              : KeyboardPage.upper;
          _index = _indexOf(_rows.length, 0);
        case KeyboardLayout.more:
          _page = _page == KeyboardPage.symbols
              ? KeyboardPage.lower
              : KeyboardPage.symbols;
          _index = _indexOf(_rows.length, 1);
        case KeyboardLayout.space:
          _type(' ');
        case KeyboardLayout.delete:
          if (_text.isNotEmpty) {
            _text = String.fromCharCodes(
              _text.runes.take(_text.runes.length - 1),
            );
          }
        case KeyboardLayout.cancel:
          Navigator.of(context).pop(null);
        case KeyboardLayout.done:
          final problem = widget.validate?.call(_text);
          if (problem != null) {
            _problem = problem;
          } else {
            Navigator.of(context).pop(_text);
          }
        default:
          _type(key);
      }
    });
  }

  void _type(String character) {
    if (_text.runes.length < widget.maxLength) _text += character;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final shown = widget.obscure ? '•' * _text.runes.length : _text;
    return InputCapture(
      active: true,
      debugLabel: 'Keyboard',
      captures: const {
        WheelInput.wheel,
        WheelInput.select,
        WheelInput.menu,
        WheelInput.skip,
        WheelInput.play,
      },
      releaseOn: const {},
      onCapture: (intent) {
        switch (intent) {
          case JogIntent(:final amount, :final page):
            if (page) {
              _step(amount.sign, 0);
            } else {
              _move(amount);
            }
          case ActivateIntent():
            _press();
          case MediaIntent(command: MediaCommand.previous):
            _step(0, -1);
          case MediaIntent(command: MediaCommand.next):
            _step(0, 1);
          case MediaIntent(command: MediaCommand.toggle):
            _step(1, 0);
          case WheelBackIntent():
            _step(-1, 0);
          case WheelMenuIntent():
            Navigator.of(context).pop(null);
          default:
            return;
        }
      },
      child: PanelScreen(
        title: widget.title,
        child: Padding(
          padding: EdgeInsets.all(theme.space.x2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Preview(
                text: shown,
                hint: _text.isEmpty ? widget.hint : null,
                problem: _problem,
              ),
              SizedBox(height: theme.space.x2),
              for (var row = 0; row < _rows.length; row++)
                _KeyRow(
                  keys: _rows[row].split(''),
                  labels: _rows[row].split(''),
                  selected: _place(_index).$1 == row ? _place(_index).$2 : null,
                ),
              const Spacer(),
              _KeyRow(
                keys: KeyboardLayout.controls,
                labels: [
                  _page == KeyboardPage.upper ? 'abc' : 'ABC',
                  _page == KeyboardPage.symbols ? 'abc' : '?12',
                  'Space',
                  'Delete',
                  'Cancel',
                  'Done',
                ],
                selected: _place(_index).$1 == _rows.length
                    ? _place(_index).$2
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.text, this.hint, this.problem});
  final String text;
  final String? hint, problem;
  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: theme.palette.divider),
            borderRadius: BorderRadius.circular(theme.space.x1),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: theme.space.x2,
              vertical: theme.space.x1,
            ),
            child: TitleText(
              text.isEmpty ? (hint ?? ' ') : text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              key: const ValueKey('keyboard-text'),
            ),
          ),
        ),
        if (problem case final problem?) ...[
          SizedBox(height: theme.space.x1),
          CaptionText(problem, key: const ValueKey('keyboard-problem')),
        ],
      ],
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.keys, required this.labels, this.selected});
  final List<String> keys, labels;
  final int? selected;
  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final palette = theme.palette;
    final ink = palette.text;
    return Padding(
      padding: EdgeInsets.only(bottom: theme.space.x1),
      child: Row(
        children: [
          for (var i = 0; i < keys.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: theme.space.x1 / 2),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: i == selected
                        ? palette.primary.s500
                        : const Color(0x00000000),
                    borderRadius: BorderRadius.circular(theme.space.x1),
                    border: Border.all(color: palette.divider),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: theme.space.x1),
                    child: Center(
                      child: DefaultTextStyle.merge(
                        style: TextStyle(
                          color: i == selected ? palette.onPrimary : ink,
                          fontWeight: i == selected ? FontWeight.bold : null,
                        ),
                        child: BodyText(
                          labels[i],
                          maxLines: 1,
                          key: ValueKey('key-${keys[i]}'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
