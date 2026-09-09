import 'player_action.dart';

/// A validated player command. Positions are milliseconds; volume is 0–1.
final class PlayerCommand {
  const PlayerCommand._(this.action, this.value);
  final PlayerAction action;
  final num? value;

  factory PlayerCommand.fromJson(Object? input) {
    if (input is! Map<String, dynamic> || input['type'] is! String) {
      throw const FormatException('Command must be an object with a type.');
    }
    final action = PlayerAction.values.where((a) => a.name == input['type']);
    if (action.isEmpty) throw const FormatException('Unknown command type.');
    final type = action.single;
    final key = switch (type) {
      PlayerAction.seek => 'positionMs',
      PlayerAction.setVolume => 'volume',
      _ => null,
    };
    if (input.keys.any((k) => k != 'type' && k != key)) {
      throw const FormatException('Unexpected command field.');
    }
    final value = key == null ? null : input[key];
    if (type == PlayerAction.seek && (value is! int || value < 0)) {
      throw const FormatException('positionMs must be a nonnegative integer.');
    }
    if (type == PlayerAction.setVolume &&
        (value is! num || !value.isFinite || value < 0 || value > 1)) {
      throw const FormatException(
        'volume must be a finite number from 0 to 1.',
      );
    }
    return PlayerCommand._(type, value as num?);
  }

  Map<String, Object?> toJson() => {
    'type': action.name,
    if (action == PlayerAction.seek) 'positionMs': value,
    if (action == PlayerAction.setVolume) 'volume': value,
  };
}
