import 'package:flutter/material.dart';

/// A bay marker pegged onto the path.
///
/// Field names/types mirror the server's device payload shape (identifier,
/// device_type, bay_type, state, is_end -- see
/// `md/parking-app-architecture.md`) so this lines up with the real merge
/// logic when server sync is eventually added. Everything here is still
/// local/mock for this build: [deviceType], [bayType], and [state] are
/// carried through but not editable from the UI (state in particular is
/// hardware truth the app never writes), and [isEnd] stays
/// user-toggleable only as a placeholder for what will eventually be a
/// hardware-driven, read-only flag.
///
/// Addressing is derived, not stored: [Bay] doesn't carry an address label
/// itself, only its arc-length position [s] (which has no server analog --
/// it's layout-only, the one thing the app actually owns and writes).
/// Address labels (s0, s1, ...) are computed on demand by sorting bays by
/// [s] -- see `deriveAddresses` in geometry/addressing.dart.
class Bay {
  /// e.g. "s0" -- zero-based within the zone, matches the server's
  /// `identifier` field.
  final String identifier;
  final int deviceType;
  final int bayType;
  final int state; // 0 = free, 1 = occupied
  final bool isEnd;
  final int section;
  final double s;

  const Bay({
    required this.identifier,
    required this.s,
    this.deviceType = 1,
    this.bayType = 0,
    this.state = 0,
    this.isEnd = false,
    this.section = 0,
  });

  Bay copyWith({double? s, bool? isEnd}) {
    return Bay(
      identifier: identifier,
      s: s ?? this.s,
      deviceType: deviceType,
      bayType: bayType,
      state: state,
      isEnd: isEnd ?? this.isEnd,
      section: section,
    );
  }

  bool get isOccupied => state == 1;

  BayPegStyling get pegStyle {
    //state 1 means its occupied
    if (isOccupied) {
      return BayPegStyling(
        fillColor: Colors.red,
        borderColor: Colors.black,
        textColor: const Color.fromARGB(255, 0, 0, 0),
      );
    }
    return switch (bayType) {
      0 => BayPegStyling(fillColor: Color.fromRGBO(149, 250, 41, 1)),
      1 => BayPegStyling(fillColor: Color.fromRGBO(248, 172, 31, 1)),
      2 => BayPegStyling(fillColor: Color.fromRGBO(31, 212, 248, 1)),
      3 => BayPegStyling(fillColor: Color.fromRGBO(255, 255, 255, 1)),
      4 => BayPegStyling(fillColor: Color.fromRGBO(177, 54, 248, 1)),
      5 => BayPegStyling(fillColor: Color.fromRGBO(246, 66, 201, 1)),
      6 => BayPegStyling(fillColor: Color.fromRGBO(76, 70, 251, 1)),
      7 => BayPegStyling(fillColor: Color.fromRGBO(241, 248, 31, 1)),
      _ => BayPegStyling(fillColor: Color.fromRGBO(132, 248, 31, 1)),
    };
  }
}

class BayPegStyling {
  const BayPegStyling({
    required this.fillColor,
    this.borderColor = Colors.black,
    this.textColor = Colors.black,
  });
  final Color fillColor;
  final Color borderColor;
  final Color textColor;
}
