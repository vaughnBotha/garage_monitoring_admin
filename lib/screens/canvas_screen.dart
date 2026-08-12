import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../geometry/addressing.dart';
import '../geometry/path_geometry.dart';
import '../models/bay.dart';
import '../models/expected_device.dart';
import '../models/floor_data.dart';
import '../models/zone_data.dart';
import '../painting/path_painter.dart';

enum CanvasMode { route, peg }

const _canvasSize = Size(1100, 720);
const _doubleClickWindow = Duration(milliseconds: 300);

// Sample sensor payload for Level 1 / Zone A (floor "SB L1", zone "ZB0"):
// 8 devices across 2 sections, with s4 and s7 flagged is_end by hardware.
const _zoneAExpectedDevices = [
  ExpectedDevice(identifier: 's0', section: 0, bayType: 2),
  ExpectedDevice(identifier: 's1', section: 0, bayType: 3),
  ExpectedDevice(identifier: 's2', section: 0, state: 1),
  ExpectedDevice(identifier: 's3', section: 0),
  ExpectedDevice(identifier: 's4', section: 0, isEnd: true),
  ExpectedDevice(identifier: 's5', section: 1),
  ExpectedDevice(identifier: 's6', section: 1),
  ExpectedDevice(identifier: 's7', section: 1, isEnd: true),
];

class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key});

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> {
  CanvasMode _mode = CanvasMode.route;

  // Mock in-memory ParkingLevel list for this build -- no server. Each
  // floor holds its own zones, and each zone keeps its own independent
  // path/bays; switching floors or zones just changes which one the
  // canvas reads and writes.
  final List<FloorData> _floors = [
    FloorData(
      id: 'level-1',
      name: 'Level 1',
      backgroundAssetPath: 'assets/floorplans/level_1.png',
      zones: [
        ZoneData(
          id: 'level-1-zone-a',
          name: 'Zone A',
          expectedDevices: _zoneAExpectedDevices,
        ),
        ZoneData(id: 'level-1-zone-b', name: 'Zone B'),
      ],
    ),
    FloorData(
      id: 'level-2',
      name: 'Level 2',
      backgroundAssetPath: 'assets/floorplans/level_2.png',
      zones: [
        ZoneData(id: 'level-2-zone-a', name: 'Zone A'),
        ZoneData(id: 'level-2-zone-b', name: 'Zone B'),
      ],
    ),
  ];
  late String _selectedFloorId = _floors.first.id;

  /// The zone currently selected for editing. Null means "Show all" -- a
  /// read-only overview of every zone on the floor at once.
  late String? _selectedZoneId = _floors.first.zones.first.id;

  FloorData get _floor => _floors.firstWhere((f) => f.id == _selectedFloorId);

  ZoneData? get _zone {
    final id = _selectedZoneId;
    if (id == null) return null;
    return _floor.zones.firstWhere((z) => z.id == id);
  }

  // Floor plan images are decoded once per floor and cached here, keyed by
  // floor id. Loading is fire-and-forget from initState; until an entry
  // shows up, the painter falls back to its plain grid background.
  final Map<String, ui.Image> _floorImages = {};

  String? _draggingBayId;
  int? _draggingWaypointIndex;
  DateTime? _lastTapTime;
  String? _lastTapBayId;

  // Hand tool: holding Space suspends route/peg clicking and switches the
  // canvas to click-drag panning instead, matching the Figma/Photoshop
  // convention. There's otherwise no mouse-drag panning at all here (only
  // the scrollbars and Ctrl/Cmd+scroll), so this is the main way to pan.
  bool _spaceHeld = false;
  bool _isPanning = false;

  static const double _minZoom = 0.5;
  static const double _maxZoom = 3.0;
  static const double _zoomStep = 0.25;
  static const double _wheelZoomSensitivity = 0.0018;
  double _zoom = 1.0;

  final ScrollController _hScrollController = ScrollController();
  final ScrollController _vScrollController = ScrollController();

  void _zoomIn() => _zoomAt(null, _zoomStep);

  void _zoomOut() => _zoomAt(null, -_zoomStep);

  void _resetZoom() => setState(() => _zoom = 1.0);

  bool get _zoomModifierPressed =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  void _handleViewportPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_zoomModifierPressed) return; // let the scroll views pan normally

    // Registering here (an ancestor of the scroll views) overwrites their
    // own registration from earlier in the same dispatch pass, so only
    // this handler fires -- without this guard, holding no modifier would
    // leave the scroll views' registration in place and they'd pan as usual.
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      final scrollEvent = resolved as PointerScrollEvent;
      final delta = -scrollEvent.scrollDelta.dy * _wheelZoomSensitivity;
      _zoomAt(scrollEvent.localPosition, delta);
    });
  }

  /// Changes zoom by [delta], keeping the map point under [viewportPosition]
  /// fixed on screen. If [viewportPosition] is null (e.g. a toolbar button
  /// press with no cursor context), zoom just changes in place.
  void _zoomAt(Offset? viewportPosition, double delta) {
    final oldZoom = _zoom;
    final newZoom = (oldZoom + delta).clamp(_minZoom, _maxZoom);
    if (newZoom == oldZoom) return;

    if (viewportPosition == null) {
      setState(() => _zoom = newZoom);
      return;
    }

    final hOffset = _hScrollController.hasClients
        ? _hScrollController.offset
        : 0.0;
    final vOffset = _vScrollController.hasClients
        ? _vScrollController.offset
        : 0.0;
    final canvasPoint = Offset(
      viewportPosition.dx + hOffset,
      viewportPosition.dy + vOffset,
    );
    final logicalPoint = canvasPoint / oldZoom;
    final newHOffset = hOffset + logicalPoint.dx * (newZoom - oldZoom);
    final newVOffset = vOffset + logicalPoint.dy * (newZoom - oldZoom);

    setState(() => _zoom = newZoom);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_hScrollController.hasClients) {
        _hScrollController.jumpTo(
          newHOffset.clamp(0.0, _hScrollController.position.maxScrollExtent),
        );
      }
      if (_vScrollController.hasClients) {
        _vScrollController.jumpTo(
          newVOffset.clamp(0.0, _vScrollController.position.maxScrollExtent),
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    for (final floor in _floors) {
      _loadFloorImage(floor);
    }
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _hScrollController.dispose();
    _vScrollController.dispose();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.space) return false;
    final isDown = event is KeyDownEvent || event is KeyRepeatEvent;
    if (isDown != _spaceHeld) {
      setState(() => _spaceHeld = isDown);
    }
    return false; // don't consume -- let it keep reaching focused widgets
  }

  Future<void> _loadFloorImage(FloorData floor) async {
    final assetPath = floor.backgroundAssetPath;
    if (assetPath == null) return;
    final data = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => _floorImages[floor.id] = frame.image);
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_spaceHeld) {
      setState(() => _isPanning = true);
      return;
    }

    final zone = _zone;
    if (zone == null) return; // "Show all" is a read-only overview

    // The canvas is rendered at logicalSize * _zoom pixels (see build()),
    // so pointer positions arrive in zoomed screen space -- divide back
    // down to logical coordinates before doing any hit-testing/geometry.
    final position = event.localPosition / _zoom;
    final isSecondary = event.buttons & kSecondaryMouseButton != 0;

    if (_mode == CanvasMode.route) {
      final hitIndex = _waypointIndexAt(zone, position);

      if (isSecondary) {
        if (hitIndex != null) {
          _removeWaypointAt(zone, hitIndex);
        } else {
          _removeLastWaypoint(zone);
        }
        return;
      }

      if (hitIndex != null) {
        _draggingWaypointIndex = hitIndex;
      } else {
        setState(() => zone.path.add(position));
      }
      return;
    }

    // Peg mode.
    final hitBay = _bayAt(zone, position);

    if (isSecondary) {
      if (hitBay != null) _removeBay(zone, hitBay.identifier);
      return;
    }

    if (hitBay != null) {
      final now = DateTime.now();
      final isDoubleClick =
          _lastTapBayId == hitBay.identifier &&
          _lastTapTime != null &&
          now.difference(_lastTapTime!) < _doubleClickWindow;
      _lastTapTime = now;
      _lastTapBayId = hitBay.identifier;

      if (isDoubleClick) {
        _toggleEnd(zone, hitBay.identifier);
        _draggingBayId = null;
      } else {
        _draggingBayId = hitBay.identifier;
      }
      return;
    }

    if (zone.path.length >= 2) {
      _addBay(zone, position);
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_isPanning) {
      if (_hScrollController.hasClients) {
        _hScrollController.jumpTo(
          (_hScrollController.offset - event.delta.dx).clamp(
            0.0,
            _hScrollController.position.maxScrollExtent,
          ),
        );
      }
      if (_vScrollController.hasClients) {
        _vScrollController.jumpTo(
          (_vScrollController.offset - event.delta.dy).clamp(
            0.0,
            _vScrollController.position.maxScrollExtent,
          ),
        );
      }
      return;
    }

    final zone = _zone;
    if (zone == null) return;
    final position = event.localPosition / _zoom;

    if (_mode == CanvasMode.route && _draggingWaypointIndex != null) {
      setState(() => zone.path[_draggingWaypointIndex!] = position);
      return;
    }

    if (_mode == CanvasMode.peg && _draggingBayId != null) {
      final snap = snapToNearestSegment(position, zone.path);
      if (snap == null) return;
      final s = arcLengthAt(zone.path, snap.segmentIndex, snap.t);
      setState(() {
        final index = zone.bays.indexWhere(
          (b) => b.identifier == _draggingBayId,
        );
        if (index != -1) {
          zone.bays[index] = zone.bays[index].copyWith(s: s);
        }
      });
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_isPanning) {
      setState(() => _isPanning = false);
    }
    _draggingBayId = null;
    _draggingWaypointIndex = null;
  }

  int? _waypointIndexAt(ZoneData zone, Offset position) {
    final path = zone.path;
    for (var i = 0; i < path.length; i++) {
      if ((path[i] - position).distance <= waypointRadius + 8) {
        return i;
      }
    }
    return null;
  }

  Bay? _bayAt(ZoneData zone, Offset position) {
    for (final bay in zone.bays) {
      final center = pointAtArcLength(zone.path, bay.s);
      if ((center - position).distance <= bayMarkerRadius + 6) {
        return bay;
      }
    }
    return null;
  }

  /// The next device from the zone's expected list that isn't pegged yet,
  /// in list order -- null once every expected identifier has a bay.
  ExpectedDevice? _nextUnpeggedDevice(ZoneData zone) {
    final peggedIds = zone.bays.map((b) => b.identifier).toSet();
    for (final device in zone.expectedDevices) {
      if (!peggedIds.contains(device.identifier)) return device;
    }
    return null;
  }

  void _addBay(ZoneData zone, Offset position) {
    final snap = snapToNearestSegment(position, zone.path);
    if (snap == null) return;
    final s = arcLengthAt(zone.path, snap.segmentIndex, snap.t);

    if (zone.expectedDevices.isNotEmpty) {
      // Hard-capped: you can't peg more devices than the hardware
      // reports, so once every expected identifier is placed, clicking
      // to add another peg does nothing.
      final device = _nextUnpeggedDevice(zone);
      if (device == null) return;
      setState(
        () => zone.bays.add(
          Bay(
            identifier: device.identifier,
            s: s,
            deviceType: device.deviceType,
            bayType: device.bayType,
            state: device.state,
            isEnd: device.isEnd,
            section: device.section,
          ),
        ),
      );
      return;
    }

    // No expected device list for this zone yet -- fall back to free-form,
    // uncapped identifiers matching the server's naming scheme.
    final identifier = 's${zone.bayCounter++}';
    setState(() => zone.bays.add(Bay(identifier: identifier, s: s)));
  }

  void _removeBay(ZoneData zone, String identifier) {
    setState(() {
      zone.bays.removeWhere((b) => b.identifier == identifier);
      if (zone.endBayId == identifier) zone.endBayId = null;
    });
  }

  void _toggleEnd(ZoneData zone, String identifier) {
    setState(() {
      zone.endBayId = zone.endBayId == identifier ? null : identifier;
      for (var i = 0; i < zone.bays.length; i++) {
        zone.bays[i] = zone.bays[i].copyWith(
          isEnd: zone.bays[i].identifier == zone.endBayId,
        );
      }
    });
  }

  void _removeLastWaypoint(ZoneData zone) {
    if (zone.path.isEmpty) return;
    setState(() => zone.path.removeLast());
  }

  void _removeWaypointAt(ZoneData zone, int index) {
    setState(() => zone.path.removeAt(index));
  }

  void _clearPath(ZoneData zone) {
    setState(() {
      zone.path.clear();
      zone.bays.clear();
      zone.endBayId = null;
      zone.bayCounter = 0;
    });
  }

  void _clearBays(ZoneData zone) {
    setState(() {
      zone.bays.clear();
      zone.endBayId = null;
      zone.bayCounter = 0;
    });
  }

  void _resetTransientInteractionState() {
    _draggingBayId = null;
    _draggingWaypointIndex = null;
    _lastTapBayId = null;
    _lastTapTime = null;
  }

  @override
  Widget build(BuildContext context) {
    final floor = _floor;
    final zone = _zone;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zone layout — route/peg test'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedFloorId,
                  icon: const Icon(Icons.arrow_drop_down),
                  items: [
                    for (final f in _floors)
                      DropdownMenuItem(value: f.id, child: Text(f.name)),
                  ],
                  onChanged: (id) {
                    if (id == null || id == _selectedFloorId) return;
                    final newFloor = _floors.firstWhere((f) => f.id == id);
                    setState(() {
                      _selectedFloorId = id;
                      _selectedZoneId = newFloor.zones.first.id;
                      _resetTransientInteractionState();
                    });
                  },
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _selectedZoneId,
                  icon: const Icon(Icons.arrow_drop_down),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Show all'),
                    ),
                    for (final z in floor.zones)
                      DropdownMenuItem<String?>(
                        value: z.id,
                        child: Text(z.name),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == _selectedZoneId) return;
                    setState(() {
                      _selectedZoneId = id;
                      _resetTransientInteractionState();
                    });
                  },
                ),
              ),
            ),
          ),
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
                    _resetTransientInteractionState();
                  });
                },
              ),
            ),
          ),
          IconButton(
            tooltip: 'Clear bays',
            onPressed: (zone == null || zone.bays.isEmpty)
                ? null
                : () => _clearBays(zone),
            icon: const Icon(Icons.push_pin),
          ),
          IconButton(
            tooltip: 'Clear path & bays',
            onPressed: (zone == null || zone.path.isEmpty)
                ? null
                : () => _clearPath(zone),
            icon: const Icon(Icons.delete_outline),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _InstructionsBar(
            mode: _mode,
            readOnly: zone == null,
            zoom: _zoom,
            minZoom: _minZoom,
            maxZoom: _maxZoom,
            onZoomIn: _zoomIn,
            onZoomOut: _zoomOut,
            onZoomReset: _resetZoom,
          ),
          Expanded(
            child: Listener(
              // Wraps (is an ancestor of) the scroll views below, so it's
              // dispatched to *after* they've already claimed the pointer
              // signal for panning -- registering here when the zoom
              // modifier is held overrides that claim for this event only.
              onPointerSignal: _handleViewportPointerSignal,
              child: Center(
                child: SingleChildScrollView(
                  controller: _hScrollController,
                  scrollDirection: Axis.horizontal,
                  child: SingleChildScrollView(
                    controller: _vScrollController,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFB8AF9A)),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      // The canvas widget is laid out at logical size *
                      // zoom so the scroll views can pan around it once
                      // zoomed in; PathPainter applies the matching scale
                      // internally so background/path/bays stay in
                      // lockstep.
                      width: _canvasSize.width * _zoom,
                      height: _canvasSize.height * _zoom,
                      child: MouseRegion(
                        cursor: _spaceHeld
                            ? (_isPanning
                                  ? SystemMouseCursors.grabbing
                                  : SystemMouseCursors.grab)
                            : MouseCursor.defer,
                        child: Listener(
                          onPointerDown: _handlePointerDown,
                          onPointerMove: _handlePointerMove,
                          onPointerUp: _handlePointerUp,
                          child: CustomPaint(
                            size: Size(
                              _canvasSize.width * _zoom,
                              _canvasSize.height * _zoom,
                            ),
                            painter: PathPainter(
                              path: zone?.path ?? const [],
                              bayLayers: zone == null
                                  ? [
                                      for (final z in floor.zones)
                                        BayLayer(
                                          path: z.path,
                                          bays: z.bays,
                                          muted: false,
                                        ),
                                    ]
                                  : [
                                      BayLayer(
                                        path: zone.path,
                                        bays: zone.bays,
                                        muted: false,
                                      ),
                                      for (final z in floor.zones)
                                        if (z.id != zone.id)
                                          BayLayer(
                                            path: z.path,
                                            bays: z.bays,
                                            muted: true,
                                          ),
                                    ],
                              otherPaths: zone == null
                                  ? [for (final z in floor.zones) z.path]
                                  : [
                                      for (final z in floor.zones)
                                        if (z.id != zone.id) z.path,
                                    ],
                              logicalSize: _canvasSize,
                              zoom: _zoom,
                              draggingBayId: _draggingBayId,
                              draggingWaypointIndex: _draggingWaypointIndex,
                              floorPlanImage: _floorImages[floor.id],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          _StatusBar(
            floorName: floor.name,
            zone: zone,
            zoneCount: floor.zones.length,
          ),
        ],
      ),
    );
  }
}

class _InstructionsBar extends StatelessWidget {
  final CanvasMode mode;
  final bool readOnly;
  final double zoom;
  final double minZoom;
  final double maxZoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomReset;

  const _InstructionsBar({
    required this.mode,
    required this.readOnly,
    required this.zoom,
    required this.minZoom,
    required this.maxZoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onZoomReset,
  });

  @override
  Widget build(BuildContext context) {
    final String actionText;
    if (readOnly) {
      actionText =
          'Showing all zones — read-only. Select a zone above to edit its route and pegs.';
    } else {
      actionText = mode == CanvasMode.route
          ? 'Route mode — click empty space to add a waypoint. Drag an existing waypoint to move it. Right-click a waypoint to remove it (right-click empty space undoes the last one).'
          : 'Peg mode — click near the path to drop a bay. Drag a bay to move it. Double-click a bay to flag/unflag it as the end sensor. Right-click a bay to remove it.';
    }
    final text =
        '$actionText Ctrl/Cmd+scroll to zoom toward the cursor. Hold Space and drag to pan.';
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
          IconButton(
            tooltip: 'Zoom out',
            onPressed: zoom <= minZoom ? null : onZoomOut,
            icon: const Icon(Icons.zoom_out),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${(zoom * 100).round()}%',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            tooltip: 'Zoom in',
            onPressed: zoom >= maxZoom ? null : onZoomIn,
            icon: const Icon(Icons.zoom_in),
          ),
          IconButton(
            tooltip: 'Reset zoom',
            onPressed: zoom == 1.0 ? null : onZoomReset,
            icon: const Icon(Icons.center_focus_strong),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final String floorName;
  final ZoneData? zone;
  final int zoneCount;

  const _StatusBar({
    required this.floorName,
    required this.zone,
    required this.zoneCount,
  });

  @override
  Widget build(BuildContext context) {
    final z = zone;
    if (z == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          '$floorName — showing all $zoneCount zones (read-only). Select a zone above to edit it.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }

    final addressed = deriveAddresses(z.bays);
    final labels = addressed
        .map((a) => a.bay.isEnd ? '${a.address}*' : a.address)
        .join('  ');

    String bayCountText;
    String remainingText = '';
    if (z.expectedDevices.isEmpty) {
      bayCountText = 'Bays: ${addressed.length}';
    } else {
      final peggedIds = addressed.map((a) => a.bay.identifier).toSet();
      final remaining = z.expectedDevices
          .where((d) => !peggedIds.contains(d.identifier))
          .map((d) => d.identifier)
          .toList();
      bayCountText =
          'Sensors pegged: ${addressed.length} of ${z.expectedDevices.length}';
      if (remaining.isNotEmpty) {
        remainingText = '   remaining: ${remaining.join(', ')}';
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(
        '$floorName / ${z.name} — Waypoints: ${z.path.length}   $bayCountText'
        '$remainingText'
        '${labels.isEmpty ? '' : '   [$labels]'}'
        '${addressed.any((a) => a.bay.isEnd) ? '   (* = mock end sensor)' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
