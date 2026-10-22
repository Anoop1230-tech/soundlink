/// CRC-16/CCITT-FALSE checksum used as the last check on every packet.
int crc16(List<int> data, [int crc = 0xFFFF]) {
  for (final byte in data) {
    crc ^= (byte & 0xFF) << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}
