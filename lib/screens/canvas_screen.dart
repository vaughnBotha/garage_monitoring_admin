import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
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

  // App-wide View/Edit toggle. In View mode only the floor dropdown is
  // shown -- zone selection, the route/peg mode toggle, clear buttons, and
  // zoom controls all disappear, and the canvas becomes a read-only
  // floor-wide overview (same rendering as picking "Show all", just
  // without a zone dropdown to pick it from). Edit mode restores
  // whichever zone was last selected.
  bool _isEditMode = false;

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

  // "Cycle" is a View-mode-only kiosk feature: auto-advance through every
  // floor, 30s each, looping. It's a level-dropdown option rather than a
  // separate control since it's really just an alternate way of driving
  // _selectedFloorId. Picking a specific floor (or leaving View mode)
  // stops it.
  static const String _cycleSentinel = '__cycle__';
  static const Duration _cycleInterval = Duration(seconds: 30);
  bool _isCycling = false;
  Timer? _cycleTimer;

  // Edit-mode-only entries appended to the bottom of the level dropdown,
  // below a separator: adding a blank level and attaching/replacing the
  // selected level's background diagram.
  static const String _dividerSentinel = '__divider__';
  static const String _addLevelSentinel = '__add_level__';
  static const String _addDiagramSentinel = '__add_diagram__';

  void _addLevel() {
    final newId = 'level-${DateTime.now().microsecondsSinceEpoch}';
    final newFloor = FloorData(
      id: newId,
      name: 'Level ${_floors.length + 1}',
      zones: [ZoneData(id: '$newId-zone-a', name: 'Zone A')],
    );
    _cycleTimer?.cancel();
    _cycleTimer = null;
    setState(() {
      _isCycling = false;
      _floors.add(newFloor);
      _selectedFloorId = newFloor.id;
      _selectedZoneId = newFloor.zones.first.id;
      _resetTransientInteractionState();
    });
  }

  Future<void> _pickDiagram(FloorData floor) async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => _floorImages[floor.id] = frame.image);
  }

  void _startCycling() {
    _cycleTimer?.cancel();
    setState(() => _isCycling = true);
    _cycleTimer = Timer.periodic(_cycleInterval, (_) => _advanceCycle());
  }

  void _advanceCycle() {
    final currentIndex = _floors.indexWhere((f) => f.id == _selectedFloorId);
    final nextFloor = _floors[(currentIndex + 1) % _floors.length];
    setState(() {
      _selectedFloorId = nextFloor.id;
      _selectedZoneId = nextFloor.zones.first.id;
      _resetTransientInteractionState();
    });
  }

  FloorData get _floor => _floors.firstWhere((f) => f.id == _selectedFloorId);

  ZoneData? get _zone {
    final id = _selectedZoneId;
    if (id == null) return null;
    return _floor.zones.firstWhere((z) => z.id == id);
  }

  /// The zone actually used for editing/rendering: [_zone] gated by View
  /// mode. Keeping [_selectedZoneId] untouched while in View mode means
  /// switching back to Edit restores whatever zone was picked before.
  ZoneData? get _effectiveZone => _isEditMode ? _zone : null;

  // Floor plan images are decoded once per floor and cached here, keyed by
  // floor id. Loading is fire-and-forget from initState; until an entry
  // shows up, the painter falls back to its plain grid background.
  final Map<String, ui.Image> _floorImages = {};

  String? _draggingBayId;
  int? _draggingWaypointIndex;
  DateTime? _lastTapTime;
  String? _lastTapBayId;

  // Kept permanently unable to take keyboard focus, on top of the
  // Space-blocking Shortcuts override in build() -- belt and braces so a
  // mouse click on a dropdown never leaves it able to react to keyboard
  // input at all, Space included.
  final FocusNode _floorDropdownFocusNode = FocusNode(canRequestFocus: false);
  final FocusNode _zoneDropdownFocusNode = FocusNode(canRequestFocus: false);

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

  /// User-facing zoom multiplier: 1.0 means "fit to window" (see
  /// [_fitScale]), not literal 1:1 pixels -- so 100% already maximizes the
  /// canvas within the available space, matching View mode's philosophy,
  /// while still leaving room to zoom in/out and pan from there.
  double _zoom = 1.0;

  /// Size of the Edit-mode canvas viewport, captured from the LayoutBuilder
  /// in build() each frame so [_fitScale] and the pointer handlers can use
  /// it outside of the widget tree.
  Size _viewportSize = Size.zero;

  /// Uniform scale that fits the fixed logical canvas ([_canvasSize])
  /// entirely within [_viewportSize] without distorting it (like
  /// BoxFit.contain) -- the baseline that [_zoom] multiplies from.
  double get _fitScale {
    if (_viewportSize.isEmpty) return 1.0;
    return math.min(
      _viewportSize.width / _canvasSize.width,
      _viewportSize.height / _canvasSize.height,
    );
  }

  /// The actual render/hit-test scale: fit-to-window baseline times the
  /// user's zoom multiplier.
  double get _effectiveZoom => _fitScale * _zoom;

  final ScrollController _hScrollController = ScrollController();
  final ScrollController _vScrollController = ScrollController();

  void _zoomIn() => _zoomAt(null, _zoomStep);

  void _zoomOut() => _zoomAt(null, -_zoomStep);

  void _resetZoom() => setState(() => _zoom = 1.0);

  bool get _zoomModifierPressed =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  void _handleViewportPointerSignal(PointerSignalEvent event) {
    if (!_isEditMode) return; // View mode auto-fits; there's nothing to zoom
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

    // The fit-to-window baseline (_fitScale) doesn't change mid-gesture,
    // only _zoom does -- so scale old/new by it consistently and the
    // anchor math below works the same as it would for a plain 1:1 zoom.
    final fitScale = _fitScale;
    final oldEffectiveZoom = fitScale * oldZoom;
    final newEffectiveZoom = fitScale * newZoom;

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
    final logicalPoint = canvasPoint / oldEffectiveZoom;
    final newHOffset =
        hOffset + logicalPoint.dx * (newEffectiveZoom - oldEffectiveZoom);
    final newVOffset =
        vOffset + logicalPoint.dy * (newEffectiveZoom - oldEffectiveZoom);

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
    _cycleTimer?.cancel();
    _hScrollController.dispose();
    _vScrollController.dispose();
    _floorDropdownFocusNode.dispose();
    _zoneDropdownFocusNode.dispose();
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

    final zone = _effectiveZone;
    if (zone == null) return; // "Show all" / View mode is a read-only overview

    // The canvas is rendered at logicalSize * _effectiveZoom pixels (see
    // build()), so pointer positions arrive in that scaled screen space --
    // divide back down to logical coordinates before doing any
    // hit-testing/geometry.
    final position = event.localPosition / _effectiveZoom;
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

    final zone = _effectiveZone;
    if (zone == null) return;
    final position = event.localPosition / _effectiveZoom;

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

  Future<bool> _confirmClear(String message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear confirmation'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _confirmAndClearPath(ZoneData zone) async {
    final confirmed = await _confirmClear(
      'Are you sure you want to clear the path and bays for ${zone.name}? '
      'This can\'t be undone.',
    );
    if (confirmed) _clearPath(zone);
  }

  Future<void> _confirmAndClearBays(ZoneData zone) async {
    final confirmed = await _confirmClear(
      'Are you sure you want to clear the bays for ${zone.name}? '
      'This can\'t be undone.',
    );
    if (confirmed) _clearBays(zone);
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

  List<BayLayer> _bayLayersFor(FloorData floor, ZoneData? zone) {
    if (zone == null) {
      return [
        for (final z in floor.zones)
          BayLayer(path: z.path, bays: z.bays, muted: false),
      ];
    }
    return [
      BayLayer(path: zone.path, bays: zone.bays, muted: false),
      for (final z in floor.zones)
        if (z.id != zone.id) BayLayer(path: z.path, bays: z.bays, muted: true),
    ];
  }

  List<List<Offset>> _otherPathsFor(FloorData floor, ZoneData? zone) {
    if (zone == null) return [for (final z in floor.zones) z.path];
    return [
      for (final z in floor.zones)
        if (z.id != zone.id) z.path,
    ];
  }

  /// The interactive canvas core (cursor + gesture handling + painting),
  /// shared between Edit mode's pannable/zoomable box and View mode's
  /// fit-to-viewport box below -- only [zoom] differs between the two.
  Widget _buildCanvasCore(FloorData floor, ZoneData? zone, double zoom) {
    return MouseRegion(
      cursor: _spaceHeld
          ? (_isPanning ? SystemMouseCursors.grabbing : SystemMouseCursors.grab)
          : MouseCursor.defer,
      child: Listener(
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        child: CustomPaint(
          size: Size(_canvasSize.width * zoom, _canvasSize.height * zoom),
          painter: PathPainter(
            path: zone?.path ?? const [],
            bayLayers: _bayLayersFor(floor, zone),
            otherPaths: _otherPathsFor(floor, zone),
            logicalSize: _canvasSize,
            zoom: zoom,
            draggingBayId: _draggingBayId,
            draggingWaypointIndex: _draggingWaypointIndex,
            floorPlanImage: _floorImages[floor.id],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final floor = _floor;
    final zone = _effectiveZone;
    // Space is reserved app-wide as the canvas pan hotkey. Without this,
    // Space still reaches whichever widget currently has focus -- e.g. the
    // level/zone dropdown button (opens it) or, once a dropdown menu is
    // open, its autofocused selected item (closes it) -- because Flutter's
    // default Space/Enter-activates-buttons behavior is wired up via
    // Actions/Shortcuts on the focused widget itself, not through
    // individual widgets' focusNode settings. Intercepting Space here, above
    // everything, and mapping it to a no-op stops it from ever reaching
    // those Shortcuts bindings, while the raw HardwareKeyboard listener in
    // _handleKeyEvent (a separate, non-widget-tree listener) still sees the
    // key events fine for pan tracking.
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.space):
            DoNothingAndStopPropagationIntent(),
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Zone layout — route/peg test'),
          actions: [
            // Wrapped in a horizontal scroller: the growing set of toolbar
            // controls (edit toggle, floor/zone dropdowns, mode toggle,
            // clear buttons) can exceed the AppBar's width on narrower
            // windows -- this lets it scroll instead of overflowing.
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Center(
                        child: TextButton.icon(
                          onPressed: () {
                            final enteringEdit = !_isEditMode;
                            // Cycling is a View-mode kiosk feature; entering
                            // Edit stops it and settles on whichever floor
                            // was showing.
                            if (enteringEdit) {
                              _cycleTimer?.cancel();
                              _cycleTimer = null;
                            }
                            setState(() {
                              _isEditMode = enteringEdit;
                              if (enteringEdit) _isCycling = false;
                              _resetTransientInteractionState();
                            });
                          },
                          icon: Icon(
                            _isEditMode
                                ? Icons.visibility_outlined
                                : Icons.edit_outlined,
                          ),
                          label: Text(_isEditMode ? 'View' : 'Edit'),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Center(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            focusNode: _floorDropdownFocusNode,
                            value: _isCycling
                                ? _cycleSentinel
                                : _selectedFloorId,
                            icon: const Icon(Icons.arrow_drop_down),
                            items: [
                              for (final f in _floors)
                                DropdownMenuItem(
                                  value: f.id,
                                  child: Text(f.name),
                                ),
                              // View-mode-only kiosk option -- not shown
                              // while editing (see the toggle above, which
                              // also stops cycling on entering Edit).
                              if (!_isEditMode)
                                const DropdownMenuItem(
                                  value: _cycleSentinel,
                                  child: Text('Cycle'),
                                ),
                              // Level-management actions, edit-mode only:
                              // adding a blank level and attaching/replacing
                              // the selected level's background diagram.
                              if (_isEditMode) ...[
                                const DropdownMenuItem(
                                  value: _dividerSentinel,
                                  enabled: false,
                                  child: Divider(height: 1),
                                ),
                                const DropdownMenuItem(
                                  value: _addLevelSentinel,
                                  child: Text('Add level'),
                                ),
                                DropdownMenuItem(
                                  value: _addDiagramSentinel,
                                  child: Text(
                                    _floorImages[floor.id] != null
                                        ? 'Update diagram'
                                        : 'Add diagram',
                                  ),
                                ),
                              ],
                            ],
                            onChanged: (id) {
                              if (id == null) return;
                              if (id == _dividerSentinel) return;
                              if (id == _cycleSentinel) {
                                _startCycling();
                                return;
                              }
                              if (id == _addLevelSentinel) {
                                _addLevel();
                                return;
                              }
                              if (id == _addDiagramSentinel) {
                                _pickDiagram(floor);
                                return;
                              }
                              if (!_isCycling && id == _selectedFloorId) return;
                              _cycleTimer?.cancel();
                              _cycleTimer = null;
                              final newFloor = _floors.firstWhere(
                                (f) => f.id == id,
                              );
                              setState(() {
                                _isCycling = false;
                                _selectedFloorId = id;
                                _selectedZoneId = newFloor.zones.first.id;
                                _resetTransientInteractionState();
                              });
                            },
                          ),
                        ),
                      ),
                    ),
                    if (_isEditMode) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Center(
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String?>(
                              focusNode: _zoneDropdownFocusNode,
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
                      // A single trash icon, context-sensitive to the
                      // route/peg mode toggle: in Route mode it clears the
                      // whole path (and its bays, since they can't exist
                      // without it); in Peg mode it clears just the bays,
                      // leaving the route intact.
                      IconButton(
                        tooltip: _mode == CanvasMode.route
                            ? 'Clear path & bays'
                            : 'Clear bays',
                        onPressed: zone == null
                            ? null
                            : _mode == CanvasMode.route
                            ? (zone.path.isEmpty
                                  ? null
                                  : () => _confirmAndClearPath(zone))
                            : (zone.bays.isEmpty
                                  ? null
                                  : () => _confirmAndClearBays(zone)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            // Hidden entirely in View mode -- along with reclaiming the
            // vertical space for the canvas, there's nothing edit-specific
            // (mode hints, zoom controls) left to show once editing is off.
            if (_isEditMode)
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
              child: _isEditMode
                  // Edit mode: fixed-size canvas at the current zoom level,
                  // panned around inside scroll views.
                  ? Listener(
                      // Wraps (is an ancestor of) the scroll views below, so
                      // it's dispatched to *after* they've already claimed
                      // the pointer signal for panning -- registering here
                      // when the zoom modifier is held overrides that claim
                      // for this event only.
                      onPointerSignal: _handleViewportPointerSignal,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // Captured for _fitScale/_effectiveZoom, which the
                          // zoom-anchor math and pointer handlers also read
                          // outside of this build -- see their definitions.
                          _viewportSize = constraints.biggest;

                          // A bare Center around a scroll view is a no-op --
                          // SingleChildScrollView always claims the full
                          // available space itself, so a canvas smaller than
                          // the viewport would otherwise sit at the
                          // scroll-origin corner instead of being centered.
                          // Forcing the scrollable content to be at least as
                          // big as the viewport (via these min constraints)
                          // gives the inner Center real slack to center
                          // within once the canvas is smaller than that --
                          // and still scrolls normally once it's bigger.
                          return SingleChildScrollView(
                            controller: _hScrollController,
                            scrollDirection: Axis.horizontal,
                            child: SingleChildScrollView(
                              controller: _vScrollController,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minWidth: constraints.maxWidth,
                                  minHeight: constraints.maxHeight,
                                ),
                                child: Center(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: const Color(0xFFB8AF9A),
                                      ),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black26,
                                          blurRadius: 8,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    // The canvas widget is laid out at
                                    // logical size * _effectiveZoom (fit-to-
                                    // window baseline times the user's zoom
                                    // multiplier) so it maximizes the
                                    // available space by default and the
                                    // scroll views can pan around it once
                                    // zoomed in further; PathPainter applies
                                    // the matching scale internally so
                                    // background/path/bays stay in lockstep.
                                    width: _canvasSize.width * _effectiveZoom,
                                    height: _canvasSize.height * _effectiveZoom,
                                    child: _buildCanvasCore(
                                      floor,
                                      zone,
                                      _effectiveZoom,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    )
                  // View mode: no zoom/pan state to manage, so scale the
                  // drawing up to fill as much of the available space as
                  // possible without distorting it, centered within
                  // whatever's left over. SizedBox.expand is required here,
                  // not Center -- Center hands FittedBox loose constraints,
                  // so it would just size to its child's native 1100x720
                  // and never actually grow to fill the viewport.
                  : SizedBox.expand(
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: SizedBox(
                          width: _canvasSize.width,
                          height: _canvasSize.height,
                          child: _buildCanvasCore(floor, zone, 1.0),
                        ),
                      ),
                    ),
            ),
            // Hidden entirely in View mode -- it's edit-scoped bookkeeping
            // (waypoint/bay counts, sensor-pegging progress) that has
            // nothing to show once editing is off.
            if (_isEditMode)
              _StatusBar(
                floorName: floor.name,
                zone: zone,
                zoneCount: floor.zones.length,
              ),
          ],
        ),
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
    // Only ever rendered while in Edit mode -- View mode hides this bar
    // entirely (see build()), so there's no "not editing" case to handle.
    final actionText = readOnly
        ? 'Showing all zones — read-only. Select a zone above to edit its route and pegs.'
        : mode == CanvasMode.route
        ? 'Route mode — click empty space to add a waypoint. Drag an existing waypoint to move it. Right-click a waypoint to remove it (right-click empty space undoes the last one).'
        : 'Peg mode — click near the path to drop a bay. Drag a bay to move it. Double-click a bay to flag/unflag it as the end sensor. Right-click a bay to remove it.';
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

// Only ever rendered while in Edit mode -- View mode hides this bar
// entirely (see build()), so there's no "not editing" case to handle here.
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
