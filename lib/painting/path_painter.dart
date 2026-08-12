import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../geometry/addressing.dart';
import '../geometry/path_geometry.dart';
import '../models/bay.dart';

const double bayMarkerRadius = 6.0; // 40% smaller than the original 10.0
const double waypointRadius = 4.0;

const Color _editablePathColor = Color(0xFFD32F2F);
const double _editablePathStrokeWidth = 4.5;
const Color _readOnlyPathColor = Color(0xFF3E5C76);
const double _readOnlyPathStrokeWidth = 3;
const Color _mutedFillColor = Color(0xFF9E9E9E);
const Color _mutedBorderColor = Color(0xFF616161);
const Color _mutedTextColor = Color(0xFF424242);

/// One zone's bays plus the path they're positioned along -- [muted]
/// controls whether they render in normal per-bay colors or the flat grey
/// "not the zone you're editing" style.
class BayLayer {
  final List<Offset> path;
  final List<Bay> bays;
  final bool muted;

  const BayLayer({required this.path, required this.bays, required this.muted});
}

class PathPainter extends CustomPainter {
  /// The currently selected/editable zone's path -- rendered in red and a
  /// bit thicker so it reads clearly as the one you can click/drag. Empty
  /// when no zone is selected (e.g. "Show all").
  final List<Offset> path;

  /// One entry per zone whose bays should be drawn.
  final List<BayLayer> bayLayers;

  /// Other zones' paths on the same floor, shown for spatial context only.
  /// These render in the plain read-only style and have no waypoint dots,
  /// since clicking/dragging only ever operates on [path].
  final List<List<Offset>> otherPaths;

  final String? draggingBayId;
  final int? draggingWaypointIndex;
  final ui.Image? floorPlanImage;

  /// Fixed logical canvas size (unaffected by zoom). All drawing below is
  /// expressed in these coordinates; [zoom] is applied once as a canvas
  /// transform so the background, path, and bay markers scale together as
  /// a single unit and never drift out of alignment with each other.
  final Size logicalSize;
  final double zoom;

  PathPainter({
    required this.path,
    required this.bayLayers,
    required this.logicalSize,
    required this.zoom,
    this.otherPaths = const [],
    this.draggingBayId,
    this.draggingWaypointIndex,
    this.floorPlanImage,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(zoom);
    _paintBackground(canvas, logicalSize);
    for (final other in otherPaths) {
      _paintPath(
        canvas,
        other,
        color: _readOnlyPathColor,
        strokeWidth: _readOnlyPathStrokeWidth,
      );
    }
    _paintPath(
      canvas,
      path,
      color: _editablePathColor,
      strokeWidth: _editablePathStrokeWidth,
    );
    _paintWaypoints(canvas);
    _paintBays(canvas);
    canvas.restore();
  }

  void _paintBackground(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (floorPlanImage != null) {
      paintImage(
        canvas: canvas,
        rect: rect,
        image: floorPlanImage!,
        fit: BoxFit.contain,
      );
      return;
    }
    // No floor plan supplied for this test build: solid placeholder
    // background with a light grid so clicks have a visual frame of
    // reference.
    canvas.drawRect(rect, Paint()..color = const Color(0xFFF4F1EA));
    final gridPaint = Paint()
      ..color = const Color(0xFFD9D3C3)
      ..strokeWidth = 1;
    const step = 40.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  void _paintPath(
    Canvas canvas,
    List<Offset> points, {
    required Color color,
    required double strokeWidth,
  }) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final uiPath = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      uiPath.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(uiPath, paint);
  }

  void _paintWaypoints(Canvas canvas) {
    final paint = Paint()..color = const Color(0xFF3E5C76);
    for (var i = 0; i < path.length; i++) {
      final isDragging = i == draggingWaypointIndex;
      canvas.drawCircle(
        path[i],
        isDragging ? waypointRadius + 2 : waypointRadius,
        paint
          ..color = const Color(
            0xFF3E5C76,
          ).withValues(alpha: isDragging ? 0.7 : 1.0),
      );
    }
  }

  void _paintBays(Canvas canvas) {
    for (final layer in bayLayers) {
      final addressed = deriveAddresses(layer.bays);
      for (final entry in addressed) {
        final bay = entry.bay;
        final center = pointAtArcLength(layer.path, bay.s);
        final isDragging = !layer.muted && bay.identifier == draggingBayId;

        final Color fillColor;
        final Color borderColor;
        final Color textColor;
        if (layer.muted) {
          fillColor = _mutedFillColor.withValues(alpha: 0.6);
          borderColor = _mutedBorderColor.withValues(alpha: 0.6);
          textColor = _mutedTextColor;
        } else {
          fillColor = bay.pegStyle.fillColor.withValues(
            alpha: isDragging ? 0.7 : 1.0,
          );
          borderColor = bay.pegStyle.borderColor;
          textColor = bay.pegStyle.textColor;
        }

        final fillPaint = Paint()..color = fillColor;
        final borderPaint = Paint()
          ..color = borderColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = bay.isEnd ? 2 : 1.0;

        final radius = bayMarkerRadius + (bay.isEnd ? 1 : 0);
        canvas.drawCircle(center, radius, fillPaint);
        canvas.drawCircle(center, radius, borderPaint);

        _paintLabel(canvas, center, '${entry.index}', textColor);
      }
    }
  }

  void _paintLabel(Canvas canvas, Offset center, String text, Color textColor) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor,
          fontSize: 7,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final labelOffset =
        center + Offset(-textPainter.width / 2, -textPainter.height / 2);
    textPainter.paint(canvas, labelOffset);
  }

  @override
  bool shouldRepaint(covariant PathPainter oldDelegate) {
    // CanvasScreen mutates _path/_bays in place (add/index-assign) rather
    // than replacing them, so the old and new painter's list fields are
    // often the same object reference by the time this runs -- list `!=`
    // would then miss real content changes. Always repainting is cheap for
    // this single-canvas test build, so just do that instead of chasing
    // reference equality.
    return true;
  }
}
