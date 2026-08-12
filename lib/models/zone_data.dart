import 'dart:ui';

import 'bay.dart';
import 'expected_device.dart';

/// Mock in-memory state for one zone (`ZoneBuffer`) on a floor: its path
/// and bays. A floor can hold several of these; switching zones swaps
/// which one the canvas reads and writes, same as switching floors does.
class ZoneData {
  final String id;
  final String name;
  final List<Offset> path = [];
  final List<Bay> bays = [];
  int bayCounter = 0;
  String? endBayId;

  /// The zone's mock "server" device list. Empty for zones with no known
  /// sensor data yet, in which case pegging falls back to free-form,
  /// uncapped identifiers. When non-empty, it's both the source of the
  /// next identifier/fields a new peg gets and a hard cap on how many
  /// pegs can be placed -- you can't peg more devices than the hardware
  /// reports.
  final List<ExpectedDevice> expectedDevices;

  ZoneData({
    required this.id,
    required this.name,
    this.expectedDevices = const [],
  });
}
