# Parking management app — architecture summary

Conceptual/design decisions only. Flutter implementation details are out of scope for this doc — see the build conversation.

## Roles and source of truth

- Sensors (hardware) are the source of truth for: device identifiers, order within a zone buffer, `state` (occupancy), `is_end` (hardware pin — flags the last sensor in the chain), and `previous_update` timestamp.
- The app is a visualisation and layout layer on top of that truth. It never writes identity, order, or `is_end` — it has no path to do so. Its write surface is layout only: positions on a map, and possibly `bay_type` if that field turns out to be software-settable (unconfirmed — it appeared as an editable dropdown, unlike the read-only `is_end` checkbox).
- "Screen" is very likely just a `device_type` value on the same Device model as sensors, not a separate structure — same ordered, zero-based sequence for both.

## Server schema (from Django admin)

- `ZoneBuffer`: identifier (e.g. `ZB0`, zero-based), name, floor (FK — floor lives on the zone buffer), `additional` (free text/JSON field, currently empty — intended home for our layout data).
- `Device`: zone_buffer (FK), identifier (e.g. `s0`, zero-based within the zone buffer), device_type (e.g. Bay Sensor — other types likely include Screen), state (e.g. Free/Occupied), bay_type (open enum — `Type 0`, `Type 1`... not fixed named categories like "disabled"), `is_end` (bool, hardware pin), previous_update (date/time).
- Open question: there's a separate `Parking Levels` entity in the same admin, not yet inspected — likely where the floor plan map image should be associated, rather than duplicating it per zone buffer. Needs a look before floor/map-loading design is final.

## Data model (conceptual)

- `ParkingLevel` (floor): map image, list of zones belonging to that floor.
- `Zone` (maps to a `ZoneBuffer`): id, `path` — an ordered list of waypoints (polyline, user-placed by clicking direction-change points; allowed to fold back on itself, no simple-path constraint), `entries` — ordered list of devices, index = address.
- `ZoneEntry` / `Device`: identifier, position on map, type (bay type or screen), derived from merging server truth with stored layout.
- Live occupancy status is kept structurally separate from layout/geometry — a status update should only trigger a status repaint, not touch path or ordering state.

## Persistence: the merge on every load

Two sources combine per zone buffer:

1. **Device list** (fetched live) — source of truth for identity, order, state, `is_end`.
2. **`additional` field JSON** (stored) — layout overlay: waypoints, each mapped device's `(x, y)` position, and a snapshot of which identifier held `is_end` at last save (needed to detect "end moved" — see below).

Merge produces three buckets per zone buffer, not a flat list:
- **Mapped** — has a stored position, still present live.
- **Unmapped** — present live, no stored position (new sensor, needs pegging). Needs its own UI surface (e.g. a staging tray) since it has no `(x, y)` to render on the canvas.
- **Orphaned** — has a stored position, no longer present live (needs cleanup).

A fourth check, "end moved," compares the currently live `is_end` holder against the snapshot from last save and flags a change (e.g. *"sensor 200 is no longer the end sensor"*).

## Reconciliation UX

- Never blocking. Drift is informational, not a gate — the rest of the app stays usable regardless of mismatches.
- Surfaces in three places simultaneously, reading off the same three buckets:
  - Non-blocking top banner with a one-line summary count, dismissible per-session but reappears (or persists as a small indicator) until actually resolved.
  - Inline markers directly on the map/canvas for the current `is_end` device and any orphaned bay — banner text alone doesn't say *where*.
  - A staging list/tray for unmapped devices, since they have no position yet to draw.

## Setup interaction model (desktop/web target — mouse, right-click)

Two distinct click modes:
- **Route mode**: click to place path waypoints (polyline, direction changes only).
- **Peg mode**: click near the route to drop a bay, snapped to nearest point on the path. Folded/near-parallel path segments need proximity-aware snapping (nearest segment to the click, not globally nearest point) to avoid mis-snapping.

Address/order is derived from arc-length position along the path, not click order — so dragging a bay to reposition it keeps addressing self-consistent. Crossing a fold point while dragging changes more than one address at once — flagged as an open UX question (silent renumber vs. explicit confirm). *(Superseded for hardware-backed devices: since order/identity is hardware truth, this mechanism only actually applies within the layout's own bookkeeping — not to anything sent back to the server.)*

Editing an existing peg: click to change type or unpeg (removes stored position only, never touches the device record). The current `is_end` device should be visually distinct on the map and specifically warned against if someone attempts to unpeg it, since unpegging cannot and does not change what the hardware reports as the end sensor.

Zone paths are expected to end near their own start point (physical run loops back toward its panel) — treated as a soft validation/highlight, not a hard constraint.

## Open questions

1. What does the `Parking Levels` model hold — is the map image stored there, and does it associate to one or many zone buffers?
2. Is `bay_type` software-editable from the app, or also hardware/admin-only like `is_end`?
3. Snap disambiguation UX for near-parallel folded path segments — visible hover hint vs. tolerance-only.
4. Should crossing a fold point while dragging a bay require explicit confirmation, given it can shift more than one bay's position in the local layout at once?
