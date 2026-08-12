import 'zone_data.dart';

/// Mock in-memory state for one floor (`ParkingLevel`): its background
/// floor plan and the zones (`ZoneBuffer`s) laid out on it.
class FloorData {
  final String id;
  final String name;
  final String? backgroundAssetPath;
  final List<ZoneData> zones;

  FloorData({
    required this.id,
    required this.name,
    this.backgroundAssetPath,
    required this.zones,
  });
}
