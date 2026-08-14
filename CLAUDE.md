# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Flutter desktop/web app testing the canvas interaction for a parking-garage visualization tool. It's a client-side layout layer on top of an IoT sensor network — this build has **no server integration**; all data is mocked and held in memory. See `md/build-prompt-canvas-test.md` for the original build spec and `md/parking-app-architecture.md` for the broader conceptual design (server schema, merge/reconciliation model, roles) that this build intentionally doesn't implement yet.

Target platforms: macOS, Linux, and web desktop (mouse + right-click), not touch. Almost no platform-specific APIs or plugins are used, so it should build on Linux without changes — verify with a real `flutter run -d linux` there, since this can't be cross-compiled or tested from macOS. The one deliberate exception is `file_picker` (native "open file" dialog for the level dropdown's "Add diagram"/"Update diagram" action) — it has first-class Linux/macOS/web support, but hasn't been build-verified on Linux, so check it there before trusting it on that platform. On macOS it also needs the `com.apple.security.files.user-selected.read-only` entitlement in both `macos/Runner/DebugProfile.entitlements` and `Release.entitlements` — the plugin checks for that key directly (regardless of whether `com.apple.security.app-sandbox` itself is on), and fails with `ENTITLEMENT_NOT_FOUND` if it's missing.

## Commands

```bash
flutter analyze              # static analysis (must be clean before considering work done)
flutter test                 # run all tests
flutter test test/geometry/path_geometry_test.dart   # run a single test file
dart format lib/ test/       # format (run after multi-file edits)
flutter run -d macos         # run on macOS desktop
flutter run -d chrome        # run on web
flutter run -d linux         # run on Linux desktop (Linux host only)
```

### macOS `flutter run` / hot reload gotcha

If `flutter run -d macos` crashes with `PathAccessException: Creation of temporary directory failed, path = '/tmp'`, it's **not** an environment/terminal issue — Flutter's default macOS scaffold ships with App Sandbox enabled (`com.apple.security.app-sandbox = true` in `macos/Runner/DebugProfile.entitlements`), which blocks the Dart VM Service's DevFS from writing to `/tmp`. This repo already has it disabled for `DebugProfile.entitlements` (Release stays sandboxed, since that matters if this ever ships via the Mac App Store). If it recurs, check that entitlement first before suspecting anything else.

If `flutter run` still can't attach a dev server in a given shell, fall back to `flutter build macos` + launching `build/macos/Build/Products/Debug/parking_garage_test.app` directly — no hot reload, but confirms the build is sound.

## Architecture

### Coordinate model: one fixed logical space, scaled for display

All route/peg geometry (`FloorData`/`ZoneData`/`Bay` positions) lives in one fixed logical coordinate space, `_canvasSize` (1100×720, defined in `canvas_screen.dart`), regardless of window size or zoom. Nothing about *where things are stored* ever changes with the viewport — only *how large that fixed space is drawn* does:

- **Edit mode**: `PathPainter` applies a single `canvas.scale(zoom)` transform before drawing background/path/waypoints/bays, so all layers scale together as one unit and can never drift out of alignment. `zoom` here is `_fitScale * _zoom` (`_effectiveZoom`) — `_fitScale` is a uniform "fit the logical canvas inside the current viewport" factor (like `BoxFit.contain`) recomputed from a `LayoutBuilder`, and `_zoom` is the user's 50%–300% multiplier on top of that baseline. This means 100% zoom already maximizes the canvas within the window rather than meaning literal 1:1 pixels.
- **View mode**: no zoom/pan state — the canvas is wrapped in `SizedBox.expand` + `FittedBox(fit: BoxFit.contain)` to scale up and center within the available space. (Don't wrap a `FittedBox` meant to fill space in `Center` — `Center` gives loose constraints, so the `FittedBox` collapses to its child's natural size instead of expanding. Learned the hard way; see git history around the View-mode canvas sizing.)
- Pointer coordinates always arrive in scaled screen space and must be divided by the current effective zoom before any hit-testing/geometry runs (see `_handlePointerDown`/`_handlePointerMove` in `canvas_screen.dart`).

### Data model

- `FloorData` (→ `ParkingLevel`) has a background floor-plan image (`assets/floorplans/*.png`, rasterized once from the source PDFs — no PDF-rendering plugin, to keep Linux compatibility) and a list of `ZoneData`. In Edit mode, the level dropdown also has (below a separator) "Add level" — appends a new in-memory `FloorData` with one empty `Zone A` and no background — and "Add diagram"/"Update diagram" (label depends on whether `_floorImages[floor.id]` is already set) for picking an image file via `file_picker` and decoding it straight into `_floorImages`, bypassing `backgroundAssetPath` (which only ever holds bundled-asset paths loaded through `rootBundle`, not user-picked files).
- `ZoneData` (→ `ZoneBuffer`) holds one zone's `path` (route waypoints) and `bays` (pegs), fully independent of every other zone. Optionally carries `expectedDevices` — a mocked "server" device list (see `ExpectedDevice`) that, when present, drives peg identifiers/fields and hard-caps how many pegs can be placed (you can't peg more devices than the hardware reports). Zones/floors with no `expectedDevices` fall back to free-form, uncapped pegging.
- `Bay` field names mirror the real device payload shape (`identifier`, `deviceType`, `bayType`, `state`, `isEnd`, `section`) so the model won't need to change shape when server sync is eventually added. `s` (arc-length position along the path) is the one field with no server analog — it's the layout data this app actually owns and writes. Addressing (`s0`, `s1`, ...) is never stored; it's derived fresh via `deriveAddresses` (sorts by `s`) any time it's needed, so drag-reordering a bay updates every address live.

### Pure geometry, kept UI-free

`geometry/path_geometry.dart` and `geometry/addressing.dart` have no Flutter/painting dependencies, so they're unit-testable in isolation (`test/geometry/path_geometry_test.dart`). The key non-obvious piece: `snapToNearestSegment` snaps a click to the nearest point on the *nearest segment*, computed independently per segment — not a single continuous nearest-point search over the whole polyline. That distinction matters once a route folds back on itself and two segments run close and parallel; the naive continuous approach can snap to the wrong segment.

### Selection model: floor → zone → (edit vs. view)

`canvas_screen.dart` is a single large `StatefulWidget` (`_CanvasScreenState`) holding all app state. Key layering:

- `_selectedFloorId` / `_selectedZoneId` (nullable — null means "Show all zones" read-only overview) pick what's being edited.
- `_isEditMode` is an orthogonal app-wide toggle. **View mode** always renders as if "Show all" were selected (via the `_effectiveZone` getter, which is `_zone` gated by `_isEditMode`) and hides all editing chrome (zone dropdown, route/peg toggle, clear button, zoom controls, status bar) — but keeps `_selectedZoneId` untouched, so switching back to Edit restores whatever was selected before. All pointer handlers gate on `_effectiveZone == null` to make View mode genuinely read-only, not just visually simplified.
- When a specific zone is selected, `PathPainter` still renders every other zone on the floor for spatial context: other routes in the plain read-only style, other zones' bays muted to grey at 60% opacity via `BayLayer(muted: true)`. Only the selected zone's path/bays render at full color and support interaction.
- View mode has a "Cycle" option in the floor dropdown (kiosk-style auto-advance through floors every 30s via `Timer.periodic`); selecting a specific floor or entering Edit mode stops it.

### Input handling

Desktop-specific interaction is built on raw `Listener`s (not `GestureDetector`), since the nearest-segment snapping and hit-testing need direct pointer control:

- Left-click: add waypoint / drop peg (mode-dependent); drag existing waypoint/peg to move it.
- Right-click: remove waypoint/peg, or undo the last waypoint if not over one.
- Double-click a peg: toggle it as the mock "end sensor" (local placeholder only — real `is_end` is hardware-driven and read-only per the architecture doc).
- Space + drag: pan (there's otherwise no mouse-drag panning, only scrollbars/Ctrl+scroll).
- Ctrl/Cmd + scroll wheel: zoom toward the cursor, implemented via `PointerSignalResolver` — the outer `Listener` only registers itself (overriding the scroll views' own pan registration) when the zoom modifier is held, so plain scrolling still pans normally.

### Out of scope (deliberately)

Per `md/build-prompt-canvas-test.md`: no server sync/HTTP calls, no merge/reconciliation logic (mapped/unmapped/orphaned device buckets), no fold-point-crossing confirmation when dragging a peg across a route fold. Flag natural extension points with `// TODO` rather than building them.
