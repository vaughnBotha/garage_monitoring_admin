import 'package:flutter_test/flutter_test.dart';
import 'package:parking_garage_test/geometry/addressing.dart';
import 'package:parking_garage_test/geometry/path_geometry.dart';
import 'package:parking_garage_test/models/bay.dart';

void main() {
  group('snapToNearestSegment', () {
    test('snaps to the midpoint of a single segment', () {
      final path = [const Offset(0, 0), const Offset(100, 0)];
      final snap = snapToNearestSegment(const Offset(40, 10), path);

      expect(snap, isNotNull);
      expect(snap!.segmentIndex, 0);
      expect(snap.point.dx, closeTo(40, 0.001));
      expect(snap.point.dy, closeTo(0, 0.001));
    });

    test('clamps to segment endpoints rather than overshooting', () {
      final path = [const Offset(0, 0), const Offset(100, 0)];
      final snap = snapToNearestSegment(const Offset(150, 5), path);

      expect(snap!.segmentIndex, 0);
      expect(snap.t, 1.0);
      expect(snap.point, const Offset(100, 0));
    });

    test('picks the nearer of two adjacent segments meeting at a vertex', () {
      final path = [
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, 100),
      ];
      final snap = snapToNearestSegment(const Offset(110, 50), path);

      expect(snap!.segmentIndex, 1); // second segment: (100,0)->(100,100)
    });

    test('folded, near-parallel segments: click snaps to the segment actually '
        'nearest to it, not just the globally nearest point', () {
      // A path that goes out and folds back close and parallel to itself:
      // segment 0: (0,0) -> (200,0)
      // segment 1: (200,0) -> (200,10)   (short connector)
      // segment 2: (200,10) -> (0,10)    (runs back, 10px above segment 0)
      final path = [
        const Offset(0, 0),
        const Offset(200, 0),
        const Offset(200, 10),
        const Offset(0, 10),
      ];

      // A click much closer to the lower segment (0) than the upper one.
      final snapLower = snapToNearestSegment(const Offset(50, 2), path);
      expect(snapLower!.segmentIndex, 0);

      // A click much closer to the upper, folded-back segment (2).
      final snapUpper = snapToNearestSegment(const Offset(50, 8), path);
      expect(snapUpper!.segmentIndex, 2);
    });

    test('returns null for a path with fewer than 2 points', () {
      expect(snapToNearestSegment(Offset.zero, []), isNull);
      expect(snapToNearestSegment(Offset.zero, [Offset.zero]), isNull);
    });
  });

  group('arc-length', () {
    final path = [
      const Offset(0, 0),
      const Offset(100, 0),
      const Offset(100, 100),
    ];

    test('totalPathLength sums segment lengths', () {
      expect(totalPathLength(path), closeTo(200, 0.001));
    });

    test('arcLengthAt accounts for preceding segments', () {
      expect(arcLengthAt(path, 0, 0.5), closeTo(50, 0.001));
      expect(arcLengthAt(path, 1, 0.0), closeTo(100, 0.001));
      expect(arcLengthAt(path, 1, 0.5), closeTo(150, 0.001));
    });

    test('pointAtArcLength is the inverse of arcLengthAt', () {
      final s = arcLengthAt(path, 1, 0.25);
      final point = pointAtArcLength(path, s);
      expect(point.dx, closeTo(100, 0.001));
      expect(point.dy, closeTo(25, 0.001));
    });

    test('pointAtArcLength clamps beyond path length to the final point', () {
      final point = pointAtArcLength(path, 9999);
      expect(point, path.last);
    });
  });

  group('deriveAddresses', () {
    test('orders bays by arc-length position, not insertion order', () {
      final bays = [
        const Bay(identifier: 's2', s: 150),
        const Bay(identifier: 's0', s: 10),
        const Bay(identifier: 's1', s: 80),
      ];

      final addressed = deriveAddresses(bays);

      expect(addressed.map((a) => a.bay.identifier).toList(), [
        's0',
        's1',
        's2',
      ]);
      expect(addressed.map((a) => a.address).toList(), ['s0', 's1', 's2']);
    });

    test('re-deriving after a move updates order live', () {
      var bays = [
        const Bay(identifier: 'a', s: 10),
        const Bay(identifier: 'b', s: 20),
      ];
      expect(deriveAddresses(bays).map((a) => a.bay.identifier).toList(), [
        'a',
        'b',
      ]);

      // Move bay 'a' past bay 'b'.
      bays = [bays[0].copyWith(s: 30), bays[1]];
      expect(deriveAddresses(bays).map((a) => a.bay.identifier).toList(), [
        'b',
        'a',
      ]);
    });
  });
}
