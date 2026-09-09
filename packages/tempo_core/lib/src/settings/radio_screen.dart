import 'dart:async';

import 'package:tomeui/tomeui.dart';

import '../content_surface.dart';
import '../panel_bar.dart';
import '../routes.dart';
import '../scale.dart';
import '../services/services.dart';
import 'setting_tile.dart';

class RadioScreen extends StatelessWidget {
  const RadioScreen({this.bluetooth = false, this.known = false, super.key});
  final bool bluetooth;
  final bool known;

  @override
  Widget build(BuildContext context) {
    final radios = PlayerServicesScope.of(context).radios;
    if (radios == null) {
      return const PanelScreen(
        title: 'Radios',
        child: ContentMessage(child: BodyText('Radio services unavailable.')),
      );
    }
    return ListenableBuilder(
      listenable: radios,
      builder: (context, _) {
        final on = bluetooth
            ? radios.bluetooth.value.status != BluetoothStatus.off
            : radios.wifi.value.status != WifiStatus.off;
        final rows = <_RadioRow>[
          if (!known)
            _RadioRow(
              bluetooth ? 'Bluetooth' : 'Wi-Fi',
              on ? 'On — select to turn off' : 'Off — select to turn on',
              () => bluetooth
                  ? radios.enableBluetooth(!on)
                  : radios.enableWifi(!on),
            ),
          _RadioRow(
            on && !known ? 'Scan again' : 'Refresh',
            null,
            () => radios.refresh(scan: on && !known),
          ),
          if (!bluetooth && !known)
            _RadioRow(
              'Saved Networks',
              null,
              () => Navigator.of(context).push(
                PanelRoute(builder: (_) => const RadioScreen(known: true)),
              ),
            ),
          if (bluetooth && on)
            for (final device in radios.devices)
              _RadioRow(
                device.name,
                device.connected
                    ? 'Connected'
                    : device.paired
                    ? 'Paired'
                    : 'Available',
                () => _open(
                  context,
                  RadioDeviceScreen(device: device, mode: radios.mode),
                ),
              ),
          if (!bluetooth && (on || known))
            for (final network in radios.networks.where(
              (n) => !known || n.id != null,
            ))
              _RadioRow(
                network.ssid,
                [
                  if (network.connected)
                    'Connected'
                  else if (network.id != null)
                    'Saved',
                  if (network.bars > 0) '${network.bars}/3 signal',
                  if (network.secured) 'Secured',
                ].join(' · '),
                () => _open(
                  context,
                  RadioNetworkScreen(network: network, mode: radios.mode),
                ),
              ),
        ];
        final error = bluetooth ? radios.bluetoothError : radios.wifiError;
        return _RadioList(
          title: known
              ? 'Saved Networks'
              : bluetooth
              ? 'Bluetooth'
              : 'Wi-Fi',
          radios: radios,
          message:
              error ??
              (on &&
                      (bluetooth
                          ? radios.devices.isEmpty
                          : radios.networks
                                .where((n) => !known || n.id != null)
                                .isEmpty)
                  ? 'Nothing found. Try scanning again.'
                  : null),
          rows: rows,
        );
      },
    );
  }

  static Future<void> _open(BuildContext context, Widget screen) =>
      Navigator.of(context).push(PanelRoute(builder: (_) => screen));
}

class RadioNetworkScreen extends StatefulWidget {
  const RadioNetworkScreen({required this.network, this.mode, super.key});
  final WifiNetwork network;
  final RadioMode? mode;
  @override
  State<RadioNetworkScreen> createState() => _RadioNetworkScreenState();
}

class _RadioNetworkScreenState extends State<RadioNetworkScreen> {
  final _password = TextEditingController();
  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radios = PlayerServicesScope.of(context).radios!;
    return ListenableBuilder(
      listenable: radios,
      builder: (context, _) {
        if (widget.mode != null && widget.mode != radios.mode) {
          return _RadioList(
            title: 'Wi-Fi',
            radios: radios,
            rows: const [],
            message: 'Radio mode changed. Go back to choose a network.',
          );
        }
        final matches = radios.networks.where(
          (n) => n.ssid == widget.network.ssid,
        );
        final n = matches.isEmpty ? widget.network : matches.first;
        final enabled = radios.wifi.value.status != WifiStatus.off;
        return _RadioList(
          title: n.ssid,
          radios: radios,
          message:
              radios.wifiError ??
              (!enabled
                  ? 'Turn on Wi-Fi to connect.'
                  : !n.supported
                  ? 'Enterprise, WEP and WPA3-only networks are not supported yet.'
                  : null),
          header: n.secured && n.id == null && n.supported
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    controller: _password,
                    obscureText: true,
                    enabled: !radios.busy,
                    placeholder: const Text('Password'),
                    onSubmitted: (_) => _join(radios, n),
                  ),
                )
              : null,
          rows: [
            if (n.secured && n.id == null && n.supported)
              _RadioRow(
                'Enter Password',
                null,
                () => Navigator.of(context).push(
                  PanelRoute(
                    builder: (_) => _RadioPasswordScreen(controller: _password),
                  ),
                ),
              ),
            if (enabled && n.supported && !n.connected)
              _RadioRow('Connect', null, () => _join(radios, n)),
            if (n.connected)
              _RadioRow('Disconnect', null, radios.disconnectWifi),
            if (n.id != null)
              _RadioRow('Forget Network', null, () async {
                await radios.forgetWifi(n);
                if (context.mounted && radios.error == null) {
                  Navigator.of(context).pop();
                }
              }),
          ],
        );
      },
    );
  }

  Future<void> _join(RadioService radios, WifiNetwork n) async {
    await radios.join(n, password: _password.text);
    if (mounted && radios.error == null) _password.clear();
  }
}

class RadioDeviceScreen extends StatelessWidget {
  const RadioDeviceScreen({required this.device, this.mode, super.key});
  final BluetoothDevice device;
  final RadioMode? mode;
  @override
  Widget build(BuildContext context) {
    final radios = PlayerServicesScope.of(context).radios!;
    return ListenableBuilder(
      listenable: radios,
      builder: (context, _) {
        if (mode != null && mode != radios.mode) {
          return _RadioList(
            title: 'Bluetooth',
            radios: radios,
            rows: const [],
            message: 'Radio mode changed. Go back to choose a device.',
          );
        }
        final matches = radios.devices.where(
          (d) => d.address == device.address,
        );
        final d = matches.isEmpty ? device : matches.first;
        return _RadioList(
          title: d.name,
          radios: radios,
          message:
              radios.bluetoothError ??
              (!d.paired
                  ? 'Put the device in pairing mode. PIN and passkey pairing are not supported yet.'
                  : d.address),
          rows: [
            if (radios.bluetooth.value.status != BluetoothStatus.off)
              _RadioRow(
                d.connected
                    ? 'Disconnect'
                    : d.paired
                    ? 'Connect'
                    : 'Pair & Connect',
                null,
                () => d.connected
                    ? radios.disconnectBluetooth(d)
                    : radios.connectBluetooth(d),
              ),
            if (d.paired)
              _RadioRow('Forget Device', null, () async {
                await radios.forgetBluetooth(d);
                if (context.mounted && radios.error == null) {
                  Navigator.of(context).pop();
                }
              }),
          ],
        );
      },
    );
  }
}

class _RadioRow {
  const _RadioRow(this.title, this.summary, this.activate);
  final String title;
  final String? summary;
  final Future<void> Function() activate;
}

class _RadioList extends StatelessWidget {
  const _RadioList({
    required this.title,
    required this.radios,
    required this.rows,
    this.message,
    this.header,
  });
  final String title;
  final RadioService radios;
  final List<_RadioRow> rows;
  final String? message;
  final Widget? header;
  @override
  Widget build(BuildContext context) {
    final scale = UiScale.of(context);
    return PanelScreen(
      title: title,
      child: Column(
        children: [
          if (radios.busy) const CaptionText('Working…'),
          if (message != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: CaptionText(
                message!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ?header,
          Expanded(
            child: PanelList(
              autofocus: true,
              itemExtent: SettingTile.extentOf(scale),
              extentOf: (i) =>
                  SettingTile.extentOf(scale, summary: rows[i].summary != null),
              onActivate: (i) {
                if (!radios.busy) unawaited(rows[i].activate());
              },
              children: [
                for (final row in rows)
                  SettingTile(
                    title: row.title,
                    summary: row.summary,
                    enabled: !radios.busy,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Character entry for the physical player, which has no touch keyboard.
class _RadioPasswordScreen extends StatefulWidget {
  const _RadioPasswordScreen({required this.controller});
  final TextEditingController controller;
  @override
  State<_RadioPasswordScreen> createState() => _RadioPasswordScreenState();
}

class _RadioPasswordScreenState extends State<_RadioPasswordScreen> {
  static const characters =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 !@#\$%^&*()-_=+[]{};:,./?~`<>|\\"\'';
  @override
  Widget build(BuildContext context) {
    final scale = UiScale.of(context);
    return PanelScreen(
      title: 'Password',
      child: Column(
        children: [
          CaptionText('${widget.controller.text.length} characters entered'),
          Expanded(
            child: PanelList(
              autofocus: true,
              itemExtent: SettingTile.extentOf(scale),
              onActivate: (i) {
                if (i == 0) {
                  Navigator.of(context).pop();
                  return;
                }
                setState(() {
                  final text = widget.controller.text;
                  if (i == 1) {
                    if (text.isNotEmpty) {
                      widget.controller.text = String.fromCharCodes(
                        text.runes.take(text.runes.length - 1),
                      );
                    }
                  } else if (text.length < 63) {
                    widget.controller.text = text + characters[i - 2];
                  }
                });
              },
              children: [
                const SettingTile(title: 'Done'),
                const SettingTile(title: 'Delete Last Character'),
                for (final c in characters.split(''))
                  SettingTile(title: c == ' ' ? 'Space' : c),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
