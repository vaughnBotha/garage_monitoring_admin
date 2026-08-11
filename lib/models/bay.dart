/// A bay marker pegged onto the path.
///
/// Addressing is derived, not stored: [Bay] only carries its arc-length
/// position [s]. Address labels (s0, s1, ...) are computed on demand by
/// sorting bays by [s] -- see `deriveAddresses` in path_geometry.dart's
/// call sites (screens/canvas_screen.dart).
class Bay {
  final String id;
  final double s;
  final bool isEnd;

  const Bay({required this.id, required this.s, this.isEnd = false});

  Bay copyWith({double? s, bool? isEnd}) {
    return Bay(id: id, s: s ?? this.s, isEnd: isEnd ?? this.isEnd);
  }
}
