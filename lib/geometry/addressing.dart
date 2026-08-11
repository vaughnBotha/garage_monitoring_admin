import '../models/bay.dart';

/// A bay paired with its derived address label (s0, s1, ...).
class AddressedBay {
  final Bay bay;
  final String address;
  final int index;

  const AddressedBay({
    required this.bay,
    required this.address,
    required this.index,
  });
}

/// Re-derives every bay's address from arc-length order, not insertion/click
/// order. Call this fresh whenever bays are added, removed, or moved.
List<AddressedBay> deriveAddresses(List<Bay> bays) {
  final sorted = [...bays]..sort((a, b) => a.s.compareTo(b.s));
  return [
    for (var i = 0; i < sorted.length; i++)
      AddressedBay(bay: sorted[i], address: 's$i', index: i),
  ];
}
