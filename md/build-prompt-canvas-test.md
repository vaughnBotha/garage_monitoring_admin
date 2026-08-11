# Build prompt — Canvas route/peg drawing test (Flutter, desktop/web)

## Context
This is the first test build of a parking management visualization app. The
app is a client-side layout layer on top of an existing IoT sensor network —
this build tests only the canvas interaction, with **no server involved**.
Target platform is desktop/web (mouse + right-click), not touch.

## Goal
A single-screen Flutter app that lets a user:
1. Load a static floor plan image onto a canvas.
2. **Route mode**: click to place waypoints, building a polyline that traces
   a cable run. The path may fold back on itself (no simple-path
   constraint). Each click adds a waypoint at a direction change.
3. **Peg mode**: click near the existing path to drop a bay marker. The bay
   snaps to the nearest point on the **nearest segment to the click** (not
   the globally nearest point on the whole path) — this matters once the
   path folds and segments run close and parallel to each other.
4. Bays are addressed by **arc-length position along the path**, not by the
   order they were clicked. Address labels (`s0`, `s1`, `s2`...) update live
   as bays are added or moved.
5. Bays can be **dragged** to a new position along the path, snapping the
   same way as placement, with the address label updating live during the
   drag.
6. One bay in the mock dataset should be flagged as a mock "end sensor" and
   rendered with a visually distinct marker (e.g. different color/border) —
   this is a placeholder for a hardware-driven `is_end` state that will
   later come from the server, not something the user sets by clicking.

## Implementation approach
Use `CustomPainter` for the canvas, not a widget stack. This is a deliberate
choice: the nearest-segment snapping math and hit-testing need direct
control that `CustomPainter` gives and a widget stack doesn't. Structure it
roughly as:
- A `PathPainter` (or similar) that draws the floor plan image, the
  polyline, and the bay markers.
- A `GestureDetector`/`Listener` wrapping the canvas that handles clicks and
  drag, translating tap/drag coordinates into canvas space.
- Separate, testable pure functions for:
  - nearest-segment-then-nearest-point snapping given a click position and
    the current path
  - arc-length position of a point along the path
  - re-deriving all bay addresses from their arc-length positions after any
    change

Keep the snapping/addressing math independent of the painter/widget code
where possible, so it can be unit tested without a running app.

## Data (mocked, in-memory only for this build)
- One hardcoded `ParkingLevel` with one floor plan image (use a placeholder
  asset or solid-color background if no image is provided).
- One hardcoded `Zone`/path, empty at start — the user draws it in route
  mode.
- Bays are created by the user in peg mode; give each a sequential mock
  identifier and an `isEnd` bool, with exactly one bay flaggable as the end
  sensor at a time (moving the flag to a new bay should unset it on the
  previous one, purely as local state — this is only a placeholder for
  demo purposes).

## Explicitly out of scope for this build
Do not implement any of the following — flag with a `// TODO` comment if a
natural extension point comes up, but don't build it:
- Server sync of any kind (no HTTP calls, no persistence beyond in-memory
  state)
- Merge/reconciliation logic (mapped/unmapped/orphaned buckets, end-moved
  detection)
- Multi-zone or multi-floor navigation — one zone, one path, one screen
- Fold-point-crossing confirmation UX — if dragging a bay across a fold
  point would silently renumber more than one bay's address, let it happen
  silently for now; this is a known open question, not something to solve
  here
- Screen-type devices, occupancy state, or any live status display
- Editing/unpegging UI polish beyond the basics (a simple "remove bay" on
  click/right-click is enough; no confirmation dialogs needed)

## Acceptance check
At the end, I should be able to:
1. Click several points to draw a folded/looping path in route mode.
2. Switch to peg mode and drop several bays near different segments,
   including near where the path folds close to itself, and see them snap
   to the correct (nearest) segment rather than the globally nearest point.
3. See bay addresses reflect arc-length order along the path, not click
   order.
4. Drag a bay along the path and watch its address update live.
5. See one bay rendered distinctly as the mock end sensor.
