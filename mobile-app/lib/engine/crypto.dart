/// Signing (Ed25519) and encryption (XChaCha20-Poly1305) with package:cryptography.
///
/// Same algorithms and parameters as core-engine/soundlink/crypto.py, so
/// packets work both ways between the phone and the laptop.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int publicKeySize = 32;
const int signatureSize = 64;
const int keySize = 32;
const int nonceSize = 24;
const int macSize = 16;

final Random _rng = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

final Ed25519 _ed25519 = Ed25519();
final Xchacha20 _aead = Xchacha20.poly1305Aead();

/// A device's signing key pair.
class Identity {
  final Uint8List seed;
  final Uint8List publicKey;
  final SimpleKeyPair _keyPair;

  Identity._(this.seed, this.publicKey, this._keyPair);

  static Future<Identity> fromSeed(List<int> seed) async {
    if (seed.length != 32) throw ArgumentError('seed must be 32 bytes');
    final kp = await _ed25519.newKeyPairFromSeed(seed);
    final pk = await kp.extractPublicKey();
    return Identity._(Uint8List.fromList(seed), Uint8List.fromList(pk.bytes), kp);
  }

  static Future<Identity> generate() => fromSeed(randomBytes(32));

  Future<Uint8List> sign(List<int> data) async {
    final sig = await _ed25519.sign(data, keyPair: _keyPair);
    return Uint8List.fromList(sig.bytes);
  }

  /// Short, human-friendly id like "3fa9 01c2 77de 5b10".
  String get fingerprint => fingerprintOf(publicKey);
}

String fingerprintOf(List<int> publicKey) {
  final hex = publicKey.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)].join(' ');
}

Future<bool> verify(List<int> publicKey, List<int> data, List<int> signature) async {
  if (publicKey.length != publicKeySize || signature.length != signatureSize) return false;
  try {
    return await _ed25519.verify(
      data,
      signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

Uint8List randomKey() => randomBytes(keySize);

// Argon2id t=2, m=16 MiB, p=1, fixed app-wide salt. A short PIN is easy to
// brute force from a recording, so PIN mode is only for low-value data.
Uint8List? _pinSalt;

Future<Uint8List> keyFromPin(String pin) async {
  _pinSalt ??= Uint8List.fromList(
    (await Sha256().hash(utf8.encode('soundlink-pin-v1'))).bytes.sublist(0, 16),
  );
  final kdf = Argon2id(parallelism: 1, memory: 16 * 1024, iterations: 2, hashLength: keySize);
  final key = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: _pinSalt!);
  return Uint8List.fromList(await key.extractBytes());
}

/// Returns ciphertext followed by the 16-byte MAC (libsodium's format).
Future<Uint8List> encrypt(List<int> key, List<int> nonce, List<int> plaintext, {List<int> aad = const []}) async {
  final box = await _aead.encrypt(plaintext, secretKey: SecretKey(key), nonce: nonce, aad: aad);
  return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
}

class DecryptError implements Exception {
  @override
  String toString() => 'decryption failed (wrong key or data was changed)';
}

Future<Uint8List> decrypt(List<int> key, List<int> nonce, List<int> data, {List<int> aad = const []}) async {
  if (data.length < macSize) throw DecryptError();
  final box = SecretBox(
    data.sublist(0, data.length - macSize),
    nonce: nonce,
    mac: Mac(data.sublist(data.length - macSize)),
  );
  try {
    return Uint8List.fromList(await _aead.decrypt(box, secretKey: SecretKey(key), aad: aad));
  } on SecretBoxAuthenticationError {
    throw DecryptError();
  }
}
