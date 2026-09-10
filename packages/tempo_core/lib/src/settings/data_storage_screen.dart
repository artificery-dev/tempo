import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';
import '../panel_bar.dart';
import '../services/services.dart';
import '../appearance.dart';
import '../scale.dart';

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
/// Where a freshly inserted card's library should live: on the card, or
/// on the player.
enum CardLibraryChoice { card, device }

/// The question a first card insert asks, over the wheel the way Power is:
/// two options on a [WheelRail], the center takes the lit one, and menu or
/// back keeps the library on the device. Device settings never move; the
/// choice is only about the media library's database and cache.
class DataStoragePrompt extends StatefulWidget {
  const DataStoragePrompt({required this.controller, this.onDone, super.key});
  final DataStorageController controller;
  final VoidCallback? onDone;
  @override
  State<DataStoragePrompt> createState() => _DataStoragePromptState();
}

class _DataStoragePromptState extends State<DataStoragePrompt> {
  final WheelRailController _rail = WheelRailController();
  static const _physics = WheelRailPhysics(weight: panelRailWeight);
  CardLibraryChoice _choice = CardLibraryChoice.card;
  bool _pending = false;
  String? _error;

  Future<void> _decide(CardLibraryChoice choice) async {
    final controller = widget.controller;
    final status = controller.value;
    if (_pending || status.busy || status.restarting) return;
    if (choice == CardLibraryChoice.card && !status.cardPresent) return;
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      if (choice == CardLibraryChoice.card) {
        await controller.setPolicy(
          DataStoragePolicy.yes,
          adoptExisting: status.cardProfileExists,
        );
      } else {
        await controller.setPolicy(DataStoragePolicy.no);
      }
      if (mounted) widget.onDone?.call();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final margin = theme.widgets.dialog
        .resolve()
        .padding
        .resolve(Directionality.of(context))
        .right;
    return ValueListenableBuilder<DataStorageStatus>(
      valueListenable: widget.controller,
      builder: (context, status, _) {
        final blocked = _pending || status.busy || status.restarting;
        return InputCapture(
          active: true,
          debugLabel: 'DataStoragePrompt',
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
              case JogIntent():
                _rail.jog(intent);
              case ActivateIntent():
                _decide(_choice);
              case MediaIntent(command: MediaCommand.previous):
                _rail.step(-1);
              case MediaIntent(command: MediaCommand.next):
                _rail.step(1);
              case WheelBackIntent() || WheelMenuIntent():
                _decide(CardLibraryChoice.device);
              default:
                return;
            }
          },
          child: Dialog(
            title: const Text('SD Card Inserted'),
            message: Text(
              status.cardProfileExists
                  ? 'This card already contains a media library. Use that '
                        'one, or keep the library data on your device? No '
                        'files will be moved either way.'
                  : 'Keep your media library data on this card? It travels '
                        'with the card, and device settings stay on the '
                        'device. No media files will be moved.',
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error ?? status.error case final error?) ...[
                  Text(error, maxLines: 3, overflow: TextOverflow.ellipsis),
                  SizedBox(height: theme.space.x2),
                ],
                if (status.restarting) ...[
                  const Text('Restarting to change storage…'),
                  SizedBox(height: theme.space.x2),
                ] else if (!status.cardPresent) ...[
                  const Text('The card was removed.'),
                  SizedBox(height: theme.space.x2),
                ],
                WheelRail<CardLibraryChoice>(
                  controller: _rail,
                  value: _choice,
                  onChanged: (choice) {
                    if (!blocked) setState(() => _choice = choice);
                  },
                  physics: _physics.copyWith(give: margin),
                  variant: SurfaceVariant.subtle,
                  segments: const [
                    SegmentOption(
                      value: CardLibraryChoice.card,
                      label: Text('Use card'),
                    ),
                    SegmentOption(
                      value: CardLibraryChoice.device,
                      label: Text('Use device'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class DataStorageScreen extends StatelessWidget {
  const DataStorageScreen({super.key});
  @override
  Widget build(BuildContext context) => PanelScreen(
    title: 'Tempo Data Location',
    child: DataStorageChoices(
      controller: PlayerServicesScope.of(context).dataStorage,
    ),
  );
}

/// Both surfaces use bootstrap-owned policy, never the ordinary Settings store.
class DataStorageChoices extends StatefulWidget {
  const DataStorageChoices({required this.controller, super.key});
  final DataStorageController? controller;
  @override
  State<DataStorageChoices> createState() => _DataStorageChoicesState();
}

class _DataStorageChoicesState extends State<DataStorageChoices> {
  bool _pending = false;
  String? _error;
  int _selected = 0;
  int? _collision;
  int? _confirmMove;
  Future<void> _choose(
    int index, {
    bool replaceExisting = false,
    bool adoptExisting = false,
    bool confirmed = false,
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
    if (!confirmed &&
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
    if (((index == 0 && !status.usingCard) ||
            (index != 0 && status.usingCard)) &&
        !replaceExisting &&
        !adoptExisting &&
        !confirmed) {
      setState(() {
        _confirmMove = index;
        _selected = 0;
      });
      return;
    }
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      await controller.setPolicy(
        DataStoragePolicy.values[index],
        replaceExisting: replaceExisting,
        adoptExisting: adoptExisting,
      );
      if (mounted) {
        setState(() {
          _collision = null;
          _confirmMove = null;
        });
      }
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
        if (!status.available &&
            status.restarting &&
            controller is RetryableDataStorage) {
          Future<void> retry() async {
            if (_pending || status.busy) return;
            setState(() {
              _pending = true;
              _error = null;
            });
            try {
              await (controller as RetryableDataStorage).retryPending();
            } catch (error) {
              if (mounted) setState(() => _error = '$error');
            } finally {
              if (mounted) setState(() => _pending = false);
            }
          }

          return InputCapture(
            active: true,
            debugLabel: 'RetryLibraryMove',
            captures: const {WheelInput.select},
            releaseOn: const {},
            onCapture: (intent) {
              if (intent is ActivateIntent) retry();
            },
            child: _layout(
              [
                const Text('Finish moving your media library'),
                const Text(
                  'Keep the original SD card inserted. Retrying resumes the same move.',
                ),
                Text(_error ?? status.error ?? 'Library move is pending.'),
              ],
              [
                Button(
                  onPressed: _pending || status.busy ? null : retry,
                  center: Text(
                    _pending || status.busy ? 'Retrying…' : 'Retry move',
                  ),
                ),
              ],
            ),
          );
        }
        final blocked = _pending || status.busy || status.restarting;
        const labels = ['Internal', 'External'];
        if (_confirmMove case final destination?) {
          void cancel() => setState(() {
            _confirmMove = null;
            _selected = 0;
          });
          return InputCapture(
            active: true,
            debugLabel: 'ConfirmStorageMove',
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
                  setState(() => _selected = (_selected + amount) % 2);
                case ActivateIntent():
                  if (_selected == 0) {
                    cancel();
                  } else {
                    _choose(destination, confirmed: true);
                  }
                case WheelBackIntent() || WheelMenuIntent():
                  cancel();
                default:
                  break;
              }
            },
            child: _layout(
              [
                Text(
                  destination == 0
                      ? 'Move library data to the SD card?'
                      : 'Move library data to internal storage?',
                ),
                const Text(
                  'Moves the library database and cache, then restarts player services. Media files stay where they are. Device settings stay internal.',
                ),
                if (_error case final error?) Text(error),
              ],
              [
                _outlined(
                  0,
                  Button(
                    onPressed: blocked ? null : cancel,
                    center: const Text('Cancel'),
                  ),
                ),
                _outlined(
                  1,
                  Button(
                    onPressed: blocked
                        ? null
                        : () => _choose(destination, confirmed: true),
                    center: const Text('Move data'),
                  ),
                ),
              ],
            ),
          );
        }
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
                      confirmed: _selected == 1,
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
                const Text('Saved media library data already exists.'),
                const Text(
                  'Moving can reuse a previous retired copy of this library. An active library cannot be overwritten.',
                ),
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
                        : () => _choose(index, confirmed: true),
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
                setState(
                  () => _selected = (_selected + amount) % labels.length,
                );
              case ActivateIntent():
                _choose(1 - _selected);
              case MediaIntent(command: MediaCommand.next):
                setState(() => _selected = (_selected + 1) % labels.length);
              case MediaIntent(command: MediaCommand.previous):
                setState(
                  () => _selected =
                      (_selected + labels.length - 1) % labels.length,
                );
              case WheelBackIntent() || WheelMenuIntent():
                Navigator.of(context).maybePop();
              default:
                break;
            }
          },
          child: _layout(
            [
              Text(
                status.available
                    ? 'Tempo Data Location'
                    : 'Choose available storage',
              ),
              if (_error ?? status.error case final error?)
                Text(
                  error,
                  maxLines: MediaQuery.sizeOf(context).width < 120 ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                ),
              if (status.available)
                Text(
                  'Preferred: ${status.policy == DataStoragePolicy.no ? 'Internal' : 'External'}',
                ),
              if (status.available)
                Text(
                  status.usingCard
                      ? 'Using external storage'
                      : 'Using internal storage',
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
                    onPressed: blocked || (i == 1 && !status.cardPresent)
                        ? null
                        : () => _choose(1 - i),
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
