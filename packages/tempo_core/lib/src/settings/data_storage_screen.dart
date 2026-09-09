import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';
import '../panel_bar.dart';
import '../services/services.dart';
import '../appearance.dart';

/// Recovery does not create a player, open a library, or load settings.
class DataStorageRecoveryApp extends StatelessWidget {
  const DataStorageRecoveryApp({
    required this.controller,
    this.wheel,
    super.key,
  });
  final DataStorageController controller;
  final ClickWheelController? wheel;
  @override
  Widget build(BuildContext context) => TomeApp(
    theme: Appearance.theme.value,
    builder: (context, child) =>
        ClickWheelInput(controller: wheel, child: child!),
    home: DataStorageChoices(controller: controller),
  );
}

/// Bounded content is essential on the physical panel: Dialog's generic
/// content column otherwise grows beyond its route's scroll viewport.
class DataStoragePrompt extends StatelessWidget {
  const DataStoragePrompt({required this.controller, this.onDone, super.key});
  final DataStorageController controller;
  final VoidCallback? onDone;
  @override
  Widget build(BuildContext context) {
    final style = ThemeProvider.of(context).widgets.dialog.resolve();
    final height =
        (MediaQuery.sizeOf(context).height -
                2 * style.margin -
                style.padding.resolve(Directionality.of(context)).vertical -
                style.gap)
            .clamp(40.0, double.infinity);
    return Dialog(
      content: SizedBox(
        height: height,
        child: DataStorageChoices(
          controller: controller,
          startup: true,
          onDone: onDone,
        ),
      ),
    );
  }
}

class DataStorageScreen extends StatelessWidget {
  const DataStorageScreen({super.key});
  @override
  Widget build(BuildContext context) => PanelScreen(
    title: 'Tempo data storage',
    child: DataStorageChoices(
      controller: PlayerServicesScope.of(context).dataStorage,
    ),
  );
}

/// Both surfaces use bootstrap-owned policy, never the ordinary Settings store.
class DataStorageChoices extends StatefulWidget {
  const DataStorageChoices({
    required this.controller,
    this.startup = false,
    this.onDone,
    super.key,
  });
  final DataStorageController? controller;
  final bool startup;
  final VoidCallback? onDone;
  @override
  State<DataStorageChoices> createState() => _DataStorageChoicesState();
}

class _DataStorageChoicesState extends State<DataStorageChoices> {
  bool _pending = false;
  String? _error;
  int _selected = 0;
  int? _collision;
  Future<void> _choose(
    int index, {
    bool replaceExisting = false,
    bool adoptExisting = false,
  }) async {
    final controller = widget.controller;
    if (controller == null ||
        _pending ||
        controller.value.busy ||
        controller.value.restarting) {
      return;
    }
    if (index == 0 && !controller.value.cardPresent) return;
    final status = controller.value;
    if (replaceExisting && !status.available) return;
    if (!widget.startup &&
        !replaceExisting &&
        !adoptExisting &&
        ((index == 0 && !status.usingCard && status.cardProfileExists) ||
            (index != 0 && status.usingCard && status.deviceProfileExists))) {
      setState(() {
        _collision = index;
        _selected = 0;
      });
      return;
    }
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      if (!widget.startup) {
        await controller.setPolicy(
          DataStoragePolicy.values[index],
          replaceExisting: replaceExisting,
          adoptExisting: adoptExisting,
        );
      } else if (index == 0) {
        await controller.adoptCardForStartup();
      } else if (index == 1) {
        controller.skipStartup();
      } else {
        await controller.setPolicy(DataStoragePolicy.no);
      }
      if (mounted && widget.startup) widget.onDone?.call();
      if (mounted) setState(() => _collision = null);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null) {
      return const Text('Tempo data storage is unavailable.');
    }
    return ValueListenableBuilder<DataStorageStatus>(
      valueListenable: controller,
      builder: (context, status, _) {
        final blocked = _pending || status.busy || status.restarting;
        final labels = widget.startup
            ? ['Yes', 'No', "Don’t Ask Again"]
            : ['Yes', 'No', 'Ask'];
        if (_collision case final index?) {
          return InputCapture(
            active: true,
            debugLabel: 'DataStorageCollision',
            captures: const {
              WheelInput.wheel,
              WheelInput.select,
              WheelInput.menu,
              WheelInput.skip,
            },
            releaseOn: const {},
            onCapture: (intent) {
              if (blocked) return;
              switch (intent) {
                case JogIntent(:final amount):
                  setState(() => _selected = (_selected + amount) % 3);
                case ActivateIntent():
                  if (_selected == 2) {
                    setState(() => _collision = null);
                  } else {
                    _choose(
                      index,
                      adoptExisting: _selected == 0,
                      replaceExisting: _selected == 1,
                    );
                  }
                case WheelBackIntent() || WheelMenuIntent():
                  setState(() => _collision = null);
                default:
                  break;
              }
            },
            child: _layout(
              [
                const Text('Saved Tempo data already exists.'),
                const Text('Moving replaces the saved data.'),
                const Text('Use existing keeps that profile.'),
                if (_error case final error?)
                  Text(
                    error,
                    maxLines: MediaQuery.sizeOf(context).width < 120 ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
              [
                _outlined(
                  0,
                  Button(
                    onPressed: blocked
                        ? null
                        : () => _choose(index, adoptExisting: true),
                    center: const Text('Use existing'),
                  ),
                ),
                _outlined(
                  1,
                  Button(
                    onPressed: blocked || !status.available
                        ? null
                        : () => _choose(index, replaceExisting: true),
                    center: const Text('Move current data'),
                  ),
                ),
                _outlined(
                  2,
                  Button(
                    onPressed: blocked
                        ? null
                        : () => setState(() => _collision = null),
                    center: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          );
        }
        return InputCapture(
          active: true,
          debugLabel: 'DataStorage',
          captures: const {
            WheelInput.wheel,
            WheelInput.select,
            WheelInput.menu,
            WheelInput.skip,
          },
          releaseOn: const {},
          onCapture: (intent) {
            if (blocked) return;
            switch (intent) {
              case JogIntent(:final amount):
                setState(() => _selected = (_selected + amount) % 3);
              case ActivateIntent():
                _choose(_selected);
              case MediaIntent(command: MediaCommand.next):
                setState(() => _selected = (_selected + 1) % 3);
              case MediaIntent(command: MediaCommand.previous):
                setState(() => _selected = (_selected + 2) % 3);
              case WheelBackIntent() || WheelMenuIntent():
                if (widget.startup) {
                  _choose(1);
                } else {
                  Navigator.of(context).maybePop();
                }
              default:
                break;
            }
          },
          child: _layout(
            [
              if (widget.startup) const Text('Use SD card data?'),
              Text(
                widget.startup
                    ? 'Use the saved Tempo profile on this card?'
                    : status.available
                    ? 'Store Tempo data on the SD card?'
                    : 'Choose available storage',
              ),
              if (_error ?? status.error case final error?)
                Text(
                  error,
                  maxLines: MediaQuery.sizeOf(context).width < 120 ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                ),
              if (!widget.startup && status.available)
                Text(
                  'Current choice: ${['Yes', 'No', 'Ask'][status.policy.index]}',
                ),
              if (!widget.startup && status.available)
                Text(
                  status.usingCard ? 'Using SD card' : 'Using device storage',
                ),
              if (!status.cardPresent)
                const Text('Insert SD, or use device data.'),
              if (status.restarting)
                const Text('Restarting to change storage…'),
            ],
            [
              for (var i = 0; i < labels.length; i++)
                _outlined(
                  i,
                  Button(
                    onPressed: blocked || (i == 0 && !status.cardPresent)
                        ? null
                        : () => _choose(i),
                    center: Text(labels[i]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _layout(List<Widget> summary, List<Widget> actions) => LayoutBuilder(
    builder: (context, constraints) => SizedBox(
      height: constraints.hasBoundedHeight
          ? constraints.maxHeight
          : MediaQuery.sizeOf(context).height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: summary,
              ),
            ),
          ),
          ...actions,
        ],
      ),
    ),
  );

  Widget _outlined(int index, Widget child) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(
        color: index == _selected
            ? const Color(0xffffffff)
            : const Color(0x00000000),
      ),
    ),
    child: child,
  );
}
