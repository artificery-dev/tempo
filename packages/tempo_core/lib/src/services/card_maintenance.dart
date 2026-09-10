import 'package:flutter/foundation.dart';

enum CardMaintenancePhase {
  idle,
  ejecting,
  ejected,
  failed,
  resuming,
  formatting,
  formatted,
}

@immutable
class CardMaintenanceStatus {
  const CardMaintenanceStatus({
    this.phase = CardMaintenancePhase.idle,
    this.error,
  });
  final CardMaintenancePhase phase;
  final String? error;
  bool get busy =>
      phase == CardMaintenancePhase.ejecting ||
      phase == CardMaintenancePhase.formatting ||
      phase == CardMaintenancePhase.resuming;
}

abstract interface class CardMaintenanceController
    implements ValueListenable<CardMaintenanceStatus> {
  Future<void> eject();
  Future<void> resume();
  Future<void> format();
}
