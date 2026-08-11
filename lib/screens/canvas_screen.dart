import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../geometry/addressing.dart';
import '../geometry/path_geometry.dart';
import '../models/bay.dart';
import '../painting/path_painter.dart';

enum CanvasMode { route, peg }

const _canvasSize = Size(1100, 720);
const _doubleClickWindow = Duration(milliseconds: 300);

class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key});

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> {
  CanvasMode _mode = CanvasMode.route;

  // Mock in-memory ParkingLevel / Zone data for this build -- no server.
  final List<Offset> _path = [];
  final List<Bay> _bays = [];
  int _bayCounter = 0;
  String? _endBayId;

  String? _draggingBayId;
  int? _draggingWaypointIndex;
  DateTime? _lastTapTime;
  String? _lastTapBayId;

  void _handlePointerDown(PointerDownEvent event) {
    final position = event.localPosition;
    final isSecondary = event.buttons & kSecondaryMouseButton != 0;

    if (_mode == CanvasMode.route) {
      final hitIndex = _waypointIndexAt(position);

      if (isSecondary) {
        if (hitIndex != null) {
          _removeWaypointAt(hitIndex);
        } else {
          _removeLastWaypoint();
        }
        return;
      }

      if (hitIndex != null) {
        _draggingWaypointIndex = hitIndex;
      } else {
        setState(() => _path.add(position));
      }
      return;
    }

    // Peg mode.
    final hitBay = _bayAt(position);

    if (isSecondary) {
      if (hitBay != null) _removeBay(hitBay.id);
      return;
    }

    if (hitBay != null) {
      final now = DateTime.now();
      final isDoubleClick = _lastTapBayId == hitBay.id &&
          _lastTapTime != null &&
          now.difference(_lastTapTime!) < _doubleClickWindow;
      _lastTapTime = now;
      _lastTapBayId = hitBay.id;

      if (isDoubleClick) {
        _toggleEnd(hitBay.id);
        _draggingBayId = null;
      } else {
        _draggingBayId = hitBay.id;
      }
      return;
    }

    if (_path.length >= 2) {
      _addBay(position);
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_mode == CanvasMode.route && _draggingWaypointIndex != null) {
      setState(() => _path[_draggingWaypointIndex!] = event.localPosition);
      return;
    }

    if (_mode == CanvasMode.peg && _draggingBayId != null) {
      final snap = snapToNearestSegment(event.localPosition, _path);
      if (snap == null) return;
      final s = arcLengthAt(_path, snap.segmentIndex, snap.t);
      setState(() {
        final index = _bays.indexWhere((b) => b.id == _draggingBayId);
        if (index != -1) {
          _bays[index] = _bays[index].copyWith(s: s);
        }
      });
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    _draggingBayId = null;
    _draggingWaypointIndex = null;
  }

  int? _waypointIndexAt(Offset position) {
    for (var i = 0; i < _path.length; i++) {
      if ((_path[i] - position).distance <= waypointRadius + 8) {
        return i;
      }
    }
    return null;
  }

  Bay? _bayAt(Offset position) {
    for (final bay in _bays) {
      final center = pointAtArcLength(_path, bay.s);
      if ((center - position).distance <= bayMarkerRadius + 6) {
        return bay;
      }
    }
    return null;
  }

  void _addBay(Offset position) {
    final snap = snapToNearestSegment(position, _path);
    if (snap == null) return;
    final s = arcLengthAt(_path, snap.segmentIndex, snap.t);
    final id = 'bay_${_bayCounter++}';
    setState(() => _bays.add(Bay(id: id, s: s)));
  }

  void _removeBay(String id) {
    setState(() {
      _bays.removeWhere((b) => b.id == id);
      if (_endBayId == id) _endBayId = null;
    });
  }

  void _toggleEnd(String id) {
    setState(() {
      _endBayId = _endBayId == id ? null : id;
      for (var i = 0; i < _bays.length; i++) {
        _bays[i] = _bays[i].copyWith(isEnd: _bays[i].id == _endBayId);
      }
    });
  }

  void _removeLastWaypoint() {
    if (_path.isEmpty) return;
    setState(() => _path.removeLast());
  }

  void _removeWaypointAt(int index) {
    setState(() => _path.removeAt(index));
  }

  void _clearPath() {
    setState(() {
      _path.clear();
      _bays.clear();
      _endBayId = null;
      _bayCounter = 0;
    });
  }

  void _clearBays() {
    setState(() {
      _bays.clear();
      _endBayId = null;
      _bayCounter = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final addressed = deriveAddresses(_bays);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zone layout — route/peg test'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: SegmentedButton<CanvasMode>(
                segments: const [
                  ButtonSegment(
                    value: CanvasMode.route,
                    label: Text('Route'),
                    icon: Icon(Icons.timeline),
                  ),
                  ButtonSegment(
                    value: CanvasMode.peg,
                    label: Text('Peg'),
                    icon: Icon(Icons.push_pin_outlined),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) {
                  setState(() {
                    _mode = selection.first;
                    _draggingBayId = null;
                    _draggingWaypointIndex = null;
                  });
                },
              ),
            ),
          ),
          IconButton(
            tooltip: 'Clear bays',
            onPressed: _bays.isEmpty ? null : _clearBays,
            icon: const Icon(Icons.push_pin),
          ),
          IconButton(
            tooltip: 'Clear path & bays',
            onPressed: _path.isEmpty ? null : _clearPath,
            icon: const Icon(Icons.delete_outline),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _InstructionsBar(mode: _mode),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFB8AF9A)),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
                      ],
                    ),
                    width: _canvasSize.width,
                    height: _canvasSize.height,
                    child: Listener(
                      onPointerDown: _handlePointerDown,
                      onPointerMove: _handlePointerMove,
                      onPointerUp: _handlePointerUp,
                      child: CustomPaint(
                        size: _canvasSize,
                        painter: PathPainter(
                          path: _path,
                          bays: _bays,
                          draggingBayId: _draggingBayId,
                          draggingWaypointIndex: _draggingWaypointIndex,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          _StatusBar(waypointCount: _path.length, addressed: addressed),
        ],
      ),
    );
  }
}

class _InstructionsBar extends StatelessWidget {
  final CanvasMode mode;

  const _InstructionsBar({required this.mode});

  @override
  Widget build(BuildContext context) {
    final text = mode == CanvasMode.route
        ? 'Route mode — click empty space to add a waypoint. Drag an existing waypoint to move it. Right-click a waypoint to remove it (right-click empty space undoes the last one).'
        : 'Peg mode — click near the path to drop a bay. Drag a bay to move it. Double-click a bay to flag/unflag it as the end sensor. Right-click a bay to remove it.';
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final int waypointCount;
  final List<AddressedBay> addressed;

  const _StatusBar({required this.waypointCount, required this.addressed});

  @override
  Widget build(BuildContext context) {
    final labels = addressed
        .map((a) => a.bay.isEnd ? '${a.address}*' : a.address)
        .join('  ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(
        'Waypoints: $waypointCount   Bays: ${addressed.length}'
        '${labels.isEmpty ? '' : '   [$labels]'}'
        '${addressed.any((a) => a.bay.isEnd) ? '   (* = mock end sensor)' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
