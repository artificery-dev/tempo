import 'dart:async';

import 'player_command.dart';
import 'player_failure.dart';
import 'player_service.dart';
import 'player_snapshot.dart';

/// The truthful startup state until a real player service is attached.
final class UnavailablePlayer implements PlayerService {
  const UnavailablePlayer();
  @override
  PlayerSnapshot get snapshot =>
      const PlayerSnapshot(revision: 0, available: false);
  @override
  Stream<PlayerSnapshot> get changes => const Stream.empty();
  @override
  Future<PlayerSnapshot> execute(PlayerCommand command) async =>
      throw const PlayerFailure(
        'player_unavailable',
        'No player is connected.',
      );
}
