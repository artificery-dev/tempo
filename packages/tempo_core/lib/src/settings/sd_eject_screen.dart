import 'package:tomeui/tomeui.dart';
import 'package:tomeui_clickwheel/tomeui_clickwheel.dart';
import '../panel_bar.dart';
import '../services/services.dart';

class SdEjectScreen extends StatefulWidget {
  const SdEjectScreen({super.key});
  @override
  State<SdEjectScreen> createState() => _SdEjectScreenState();
}

class _SdEjectScreenState extends State<SdEjectScreen> {
  int _selected = 0;
  @override
  Widget build(BuildContext context) {
    final controller = PlayerServicesScope.of(context).cardMaintenance;
    return PanelScreen(
      title: 'Eject SD Card',
      child: controller == null
          ? const Text('Card maintenance is unavailable.')
          : ValueListenableBuilder<CardMaintenanceStatus>(
              valueListenable: controller,
              builder: (context, state, _) {
                final done = state.phase == CardMaintenancePhase.ejected;
                final failed = state.phase == CardMaintenancePhase.failed;
                final actions = <(String, VoidCallback)>[
                  (
                    done ? 'Close' : 'Cancel',
                    () => Navigator.of(context).maybePop(),
                  ),
                  if (!done)
                    (
                      failed ? 'Retry eject' : 'Eject card',
                      () {
                        controller.eject();
                      },
                    ),
                  if (failed)
                    (
                      'Resume library',
                      () {
                        controller.resume();
                      },
                    ),
                ];
                final selected = _selected.clamp(0, actions.length - 1);
                return InputCapture(
                  active: true,
                  debugLabel: 'EjectSD',
                  captures: const {
                    WheelInput.wheel,
                    WheelInput.select,
                    WheelInput.menu,
                  },
                  releaseOn: const {},
                  onCapture: (intent) {
                    if (state.busy) return;
                    switch (intent) {
                      case JogIntent(:final amount):
                        setState(
                          () =>
                              _selected = (selected + amount) % actions.length,
                        );
                      case ActivateIntent():
                        actions[selected].$2();
                      case WheelBackIntent() || WheelMenuIntent():
                        Navigator.of(context).maybePop();
                      default:
                        break;
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(switch (state.phase) {
                        CardMaintenancePhase.idle =>
                          'Stop playback and safely eject the SD card?',
                        CardMaintenancePhase.ejecting =>
                          'Finishing library work and ejecting…',
                        CardMaintenancePhase.ejected =>
                          'You can now remove the SD card.',
                        CardMaintenancePhase.failed =>
                          'The card could not be ejected. Keep it inserted.',
                        CardMaintenancePhase.formatting =>
                          'Formatting the SD card…',
                        CardMaintenancePhase.formatted => 'SD card formatted.',
                        CardMaintenancePhase.resuming =>
                          'Resuming the library…',
                      }),
                      if (failed)
                        const Text(
                          'Playback remains stopped. Retry, or resume using the library.',
                        ),
                      if (state.error != null)
                        Text(
                          state.error!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      for (var i = 0; i < actions.length; i++)
                        Button(
                          onPressed: state.busy ? null : actions[i].$2,
                          center: Text(
                            '${selected == i ? '› ' : ''}${actions[i].$1}',
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
