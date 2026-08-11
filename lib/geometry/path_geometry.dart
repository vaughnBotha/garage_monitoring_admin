import 'dart:ui';

/// Pure geometry helpers for the route/peg canvas. No Flutter widget or
/// painting dependencies here so this file can be unit tested in isolation.

/// Result of snapping a click to the path.
class SegmentSnap {
  final Offset point;
  final int segmentIndex;
  final double t; // 0..1 position along the segment
  final double distance;

  const SegmentSnap({
    required this.point,
    required this.segmentIndex,
    required this.t,
    required this.distance,
  });
}

/// Finds the closest point on [path] to [click], using nearest-segment-then-
/// nearest-point: the closest point is computed independently for every
/// segment, and the segment with the smallest resulting distance wins.
///
/// This is deliberately not a single continuous nearest-point search over
/// the whole polyline. Once a path folds back on itself, two segments can
/// run close and parallel to each other; picking per-segment first (rather
/// than treating the path as one continuous curve) is what keeps a click
/// snapping to the segment it's actually next to.
SegmentSnap? snapToNearestSegment(Offset click, List<Offset> path) {
  if (path.length < 2) return null;

  SegmentSnap? best;
  for (var i = 0; i < path.length - 1; i++) {
    final a = path[i];
    final b = path[i + 1];
    final ab = b - a;
    final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;

    double t;
    if (lengthSquared == 0) {
      t = 0;
    } else {
      final ac = click - a;
      final rawT = (ac.dx * ab.dx + ac.dy * ab.dy) / lengthSquared;
      t = rawT.clamp(0.0, 1.0);
    }

    final point = a + ab * t;
    final distance = (point - click).distance;

    if (best == null || distance < best.distance) {
      best = SegmentSnap(
        point: point,
        segmentIndex: i,
        t: t,
        distance: distance,
      );
    }
  }
  return best;
}

double segmentLength(List<Offset> path, int index) =>
    (path[index + 1] - path[index]).distance;

double totalPathLength(List<Offset> path) {
  var total = 0.0;
  for (var i = 0; i < path.length - 1; i++) {
    total += segmentLength(path, i);
  }
  return total;
}

/// Arc-length distance from the start of [path] to a point [t] (0..1) along
/// segment [segmentIndex].
double arcLengthAt(List<Offset> path, int segmentIndex, double t) {
  var s = 0.0;
  for (var i = 0; i < segmentIndex; i++) {
    s += segmentLength(path, i);
  }
  s += segmentLength(path, segmentIndex) * t;
  return s;
}

/// Inverse of [arcLengthAt]: the point on [path] at arc-length [s].
Offset pointAtArcLength(List<Offset> path, double s) {
  if (path.isEmpty) return Offset.zero;
  if (path.length == 1) return path.first;

  final clamped = s.clamp(0.0, totalPathLength(path));
  var remaining = clamped;

  for (var i = 0; i < path.length - 1; i++) {
    final len = segmentLength(path, i);
    final isLastSegment = i == path.length - 2;
    if (remaining <= len || isLastSegment) {
      final t = len == 0 ? 0.0 : (remaining / len).clamp(0.0, 1.0);
      return path[i] + (path[i + 1] - path[i]) * t;
    }
    remaining -= len;
  }
  return path.last;
}
