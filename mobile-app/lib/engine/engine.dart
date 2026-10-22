/// SoundLink core engine (Dart port of core-engine/soundlink).
library;

export 'crc.dart';
export 'crypto.dart';
export 'fec.dart' show FecError, rsEncode, rsDecode, encodedLen;
export 'link.dart';
export 'modem.dart';
export 'modules.dart';
export 'packet.dart';
export 'wav.dart';
