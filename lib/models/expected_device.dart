/// One entry from the mock "server" device list for a zone -- the shape
/// mirrors the sample sensor payload (identifier, section, device_type,
/// bay_type, state, is_end). This stands in for what would eventually be
/// fetched live; a zone's [ExpectedDevice]s are the source of truth for
/// which identifiers exist and how many there are, matching the real
/// merge model where identity/order comes from the device list, not the
/// stored layout.
class ExpectedDevice {
  final String identifier;
  final int section;
  final int deviceType;
  final int bayType;
  final int state;
  final bool isEnd;

  const ExpectedDevice({
    required this.identifier,
    required this.section,
    this.deviceType = 1,
    this.bayType = 0,
    this.state = 0,
    this.isEnd = false,
  });
}
