/// Fallback when sound doesn't work: the same signed packet can go by QR code
/// or by Bluetooth / Wi-Fi (Google Nearby Connections). Whatever arrives is
/// fed into the normal receiver, so it gets exactly the same checks as sound
/// (CRC, signature, decryption, replay rules of each feature).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import '../engine/engine.dart';
import '../engine/transport.dart' as transport;

/// Something that can take chunks from another channel (a SoundListener).
abstract class ChunkSink {
  bool get listening;
  Future<void> injectChunk(Uint8List chunk);
}

class FallbackHub extends ChangeNotifier {
  FallbackHub._();
  static final FallbackHub instance = FallbackHub._();

  /// The last packet this phone played, to show again as QR / send by Bluetooth.
  Uint8List? lastPacket;
  DateTime? lastAt;
  final List<ChunkSink> _sinks = [];

  void remember(List<int> raw) {
    lastPacket = Uint8List.fromList(raw);
    lastAt = DateTime.now();
    notifyListeners();
  }

  void register(ChunkSink s) => _sinks.add(s);
  void unregister(ChunkSink s) => _sinks.remove(s);

  /// Give a chunk to every screen that is listening right now; if none is,
  /// to the main Receive screen (the first one registered).
  Future<int> inject(Uint8List chunk) async {
    final targets = _sinks.where((s) => s.listening).toList();
    if (targets.isEmpty && _sinks.isNotEmpty) targets.add(_sinks.first);
    for (final s in targets) {
      await s.injectChunk(chunk);
    }
    return targets.length;
  }

  /// A whole packet that arrived by Bluetooth: wrap it as one chunk.
  Future<void> injectPacket(Uint8List raw) async {
    for (final c in transport.split(raw, frameSize: raw.length + transport.chunkHeader)) {
      await inject(c);
    }
  }
}

// ---------------------------------------------------------------- Bluetooth / Nearby

const _service = 'com.anoop.soundlink';

Future<bool> nearbyPermissions() async {
  final res = await [
    Permission.bluetoothScan,
    Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
    Permission.nearbyWifiDevices,
    Permission.locationWhenInUse, // only asked on Android 11 and older
  ].request();
  // On new phones location is not needed; on old ones Bluetooth perms don't exist.
  bool ok(Permission p) => res[p]?.isGranted == true || res[p]?.isLimited == true || res[p] == PermissionStatus.restricted;
  final bt = ok(Permission.bluetoothScan) && ok(Permission.bluetoothConnect) && ok(Permission.bluetoothAdvertise);
  return bt || ok(Permission.locationWhenInUse);
}

/// Sends one packet to the first phone that connects, or receives packets.
class NearbyLink {
  final Nearby _n = Nearby();
  final String name;
  final void Function(String) onStatus;
  NearbyLink(this.name, this.onStatus);

  Future<void> send(Uint8List packet) async {
    final ok = await _n.startAdvertising(
      name,
      Strategy.P2P_POINT_TO_POINT,
      serviceId: _service,
      onConnectionInitiated: (id, info) {
        onStatus('Connecting to ${info.endpointName}…');
        _n.acceptConnection(id, onPayLoadRecieved: (_, _) {});
      },
      onConnectionResult: (id, status) async {
        if (status != Status.CONNECTED) return onStatus('Connection failed, try again');
        await _n.sendBytesPayload(id, packet);
        onStatus('Sent ${packet.length} bytes');
        await Future<void>.delayed(const Duration(seconds: 2));
        await _n.disconnectFromEndpoint(id);
      },
      onDisconnected: (_) {},
    );
    onStatus(ok ? 'Waiting for the other phone (Receive by Bluetooth)…' : 'Could not start Bluetooth');
  }

  Future<void> receive(Future<void> Function(Uint8List) onPacket) async {
    final ok = await _n.startDiscovery(
      name,
      Strategy.P2P_POINT_TO_POINT,
      serviceId: _service,
      onEndpointFound: (id, epName, _) {
        onStatus('Found $epName, connecting…');
        _n.requestConnection(
          name,
          id,
          onConnectionInitiated: (id, info) => _n.acceptConnection(id, onPayLoadRecieved: (_, p) async {
            if (p.type == PayloadType.BYTES && p.bytes != null && p.bytes!.length <= maxPayload + 200) {
              await onPacket(p.bytes!);
            }
          }),
          onConnectionResult: (_, s) => onStatus(s == Status.CONNECTED ? 'Connected, waiting for data…' : 'Connection failed'),
          onDisconnected: (_) => onStatus('Disconnected'),
        );
      },
      onEndpointLost: (_) {},
    );
    onStatus(ok ? 'Looking for a phone that is sending…' : 'Could not start Bluetooth');
  }

  Future<void> stop() async {
    await _n.stopAdvertising();
    await _n.stopDiscovery();
    await _n.stopAllEndpoints();
  }
}
