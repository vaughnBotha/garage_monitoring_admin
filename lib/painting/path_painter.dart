import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../geometry/addressing.dart';
import '../geometry/path_geometry.dart';
import '../models/bay.dart';

const double bayMarkerRadius = 10.0;
const double waypointRadius = 4.0;

class PathPainter extends CustomPainter {
  final List<Offset> path;
  final List<Bay> bays;
  final String? draggingBayId;
  final int? draggingWaypointIndex;
  final ui.Image? floorPlanImage;

  PathPainter({
    required this.path,
    required this.bays,
    this.draggingBayId,
    this.draggingWaypointIndex,
    this.floorPlanImage,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackground(canvas, size);
    _paintPath(canvas);
    _paintWaypoints(canvas);
    _paintBays(canvas);
  }

  void _paintBackground(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (floorPlanImage != null) {
      paintImage(canvas: canvas, rect: rect, image: floorPlanImage!, fit: BoxFit.cover);
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

  void _paintPath(Canvas canvas) {
    if (path.length < 2) return;
    final paint = Paint()
      ..color = const Color(0xFF3E5C76)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final uiPath = Path()..moveTo(path.first.dx, path.first.dy);
    for (final point in path.skip(1)) {
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
        paint..color = const Color(0xFF3E5C76).withValues(alpha: isDragging ? 0.7 : 1.0),
      );
    }
  }

  void _paintBays(Canvas canvas) {
    final addressed = deriveAddresses(bays);
    for (final entry in addressed) {
      final bay = entry.bay;
      final center = pointAtArcLength(path, bay.s);
      final isDragging = bay.id == draggingBayId;

      final fillColor = bay.isEnd ? const Color(0xFFC1440E) : const Color(0xFF1B998B);
      final fillPaint = Paint()..color = fillColor.withValues(alpha: isDragging ? 0.7 : 1.0);
      final borderPaint = Paint()
        ..color = bay.isEnd ? const Color(0xFF7A2A08) : const Color(0xFF0F5C53)
        ..style = PaintingStyle.stroke
        ..strokeWidth = bay.isEnd ? 3 : 2;

      final radius = bayMarkerRadius + (bay.isEnd ? 2 : 0);
      canvas.drawCircle(center, radius, fillPaint);
      canvas.drawCircle(center, radius, borderPaint);

      _paintLabel(canvas, center, '${entry.index}');
    }
  }

  void _paintLabel(Canvas canvas, Offset center, String text) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final labelOffset = center + Offset(-textPainter.width / 2, -textPainter.height / 2);
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
