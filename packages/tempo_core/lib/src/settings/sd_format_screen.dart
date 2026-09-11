import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';
import '../panel_bar.dart';
import '../services/services.dart';

class SdFormatScreen extends StatefulWidget {
  const SdFormatScreen({super.key});
  @override
  State<SdFormatScreen> createState() => _SdFormatScreenState();
}

class _SdFormatScreenState extends State<SdFormatScreen> {
  bool _confirm = false, _busy = false, _done = false;
  String? _error;
  int _selected = 0;
  Future<void> _format() async {
    if (_busy) return;
    final services = PlayerServicesScope.of(context);
    final storage = services.dataStorage;
    if (storage == null ||
        !storage.value.available ||
        storage.value.usingCard ||
        storage.value.busy ||
        storage.value.restarting) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final maintenance = services.cardMaintenance;
      if (maintenance == null) {
        throw StateError('Card maintenance is unavailable');
      }
      await maintenance.format();
      if (maintenance.value.phase != CardMaintenancePhase.formatted) {
        throw StateError(
          maintenance.value.error ?? 'Card could not be released',
        );
      }
      if (mounted) {
        setState(() {
          _done = true;
          _confirm = false;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final storage = PlayerServicesScope.of(context).dataStorage;
    return PanelScreen(
      title: 'Format SD Card',
      child: storage == null
          ? const Text('Storage service unavailable.')
          : ValueListenableBuilder(
              valueListenable: storage,
              builder: (context, status, _) {
                final available =
                    status.available &&
                    !status.usingCard &&
                    !status.busy &&
                    !status.restarting;
                return InputCapture(
                  active: true,
                  debugLabel: 'FormatSD',
                  captures: const {
                    WheelInput.wheel,
                    WheelInput.select,
                    WheelInput.menu,
                  },
                  releaseOn: const {},
                  onCapture: (intent) {
                    if (_busy) return;
                    switch (intent) {
                      case JogIntent(:final amount):
                        setState(() => _selected = (_selected + amount) % 2);
                      case ActivateIntent():
                        if (_selected == 0) {
                          Navigator.of(context).maybePop();
                        } else if (available && !_done) {
                          if (_confirm) {
                            _format();
                          } else {
                            setState(() {
                              _confirm = true;
                              _selected = 0;
                            });
                          }
                        }
                      case WheelBackIntent() || WheelMenuIntent():
                        Navigator.of(context).maybePop();
                      default:
                        break;
                    }
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _done
                            ? 'SD card formatted as exFAT.'
                            : _busy
                            ? 'Formatting SD card…'
                            : _confirm
                            ? 'Erase everything on the SD card?'
                            : 'Format the SD card as exFAT.',
                      ),
                      if (!_done)
                        const Text(
                          'All files and partitions on the card will be erased. This cannot be undone.',
                        ),
                      if (!available)
                        const Text(
                          'Switch Tempo Data Location to Internal before formatting.',
                        ),
                      if (_error != null) Text(_error!),
                      if (_busy)
                        const Text(
                          'Keep the card inserted until formatting finishes.',
                        ),
                      Button(
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).maybePop(),
                        center: Text(_selected == 0 ? '› Cancel' : 'Cancel'),
                      ),
                      Button(
                        onPressed: _busy || !available || _done
                            ? null
                            : () {
                                if (_confirm) {
                                  _format();
                                } else {
                                  setState(() {
                                    _confirm = true;
                                    _selected = 0;
                                  });
                                }
                              },
                        center: Text(
                          '${_selected == 1 ? '› ' : ''}${_confirm ? 'Erase and format' : 'Format SD card'}',
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
