# SoundLink

Send data between devices using sound. No internet, no Bluetooth, no pairing.

SoundLink is a secure, offline platform for sharing small pieces of data through a speaker and a microphone: payments, Wi-Fi passwords, contacts, attendance, tickets, door unlock, login, emergency alerts and more. Every feature uses the same core engine; only the data inside the packet changes.

> Status: **Phase 1 done** (core engine, Python prototype). The mobile app comes next.

## How it works

```
 data ─► packet (type, id, time) ─► compress ─► encrypt ─► sign ─► CRC
      ─► split into frames ─► Reed-Solomon ─► MFSK tones ─► speaker

 mic ─► band-pass filter ─► find chirp ─► read tones ─► Reed-Solomon
     ─► join frames ─► CRC ─► check signature ─► decrypt ─► replay check ─► data
```

| Part | What it does |
|---|---|
| `packet.py` | Common packet format for every feature, plus compression, encryption (XSalsa20-Poly1305), Ed25519 signature, CRC-16 and replay protection |
| `modem.py` | Our own multi-tone FSK modem: chirp preamble for timing, 4 tone groups x 16 tones, tone rotation, streaming decoder |
| `fec.py` | Reed-Solomon error correction that uses tone confidence to fix up to 2x more errors |
| `transport.py` | Splits big packets into frames and puts them back together |
| `link.py` | Simple API: `SoundLink.encode(packet)` and `Receiver.feed(mic_audio)` |
| `sim.py` | Fake room (echo, noise, clock drift) for testing without a speaker |

### Packet format

```
| ver(1) | type(1) | flags(1) | msg_id(4) | timestamp(4) | body(N) | public key(32) + signature(64) | crc(2) |
```

The public key and signature are only present if the packet is signed. Packet types: `0x01-0x03` payment, `0x10` Wi-Fi, `0x11` contact, `0x12` file handshake, `0x20` attendance, `0x21` ticket, `0x22` door unlock, `0x30/0x31` login, `0x40` emergency, `0x50` offer, `0x60` sensor.

### Profiles

| Profile | Band | Best for |
|---|---|---|
| `normal` | 1.5-5.5 kHz (audible) | default, most reliable |
| `fast` | 1.5-9.5 kHz (audible) | quiet rooms, about 2x faster |
| `ultrasonic` | 18-20 kHz (almost silent) | attendance, beacons, offers |

## Benchmark (simulated room with echo and clock drift)

`python -m soundlink bench --trials 6 --snr 20 10 5 3`

| Profile | 200-byte message | Speed | Success at 3 dB noise |
|---|---|---|---|
| normal | 11.0 s | 18 B/s | 100% |
| fast | 5.8 s | 34 B/s | 100% |
| ultrasonic | 19.0 s | 10.5 B/s | 100% |

For comparison, ggwave does about 8-16 B/s. These numbers come from the simulator; real speaker and mic results will be added after testing on devices.

## Try it

```powershell
cd core-engine
python -m venv .venv
.venv\Scripts\activate
pip install -e .[dev]

pytest                                        # run all tests
python -m soundlink bench                     # noise benchmark, no speaker needed

python -m soundlink keygen me.key             # create your signing key
python -m soundlink listen                    # laptop 1: listen on the mic
python -m soundlink send "hello" --key-file me.key   # laptop 2: play through the speaker

python -m soundlink send "wifi-pass" --pin 1234      # encrypted with a PIN
python -m soundlink listen --pin 1234

python -m soundlink loopback                  # one laptop: speaker -> own mic
python -m soundlink encode "hi" hi.wav        # save as WAV / decode a recording
python -m soundlink decode hi.wav
```

## Security notes

- Anyone nearby can record the sound, so anything that does an action (payment, door unlock, attendance) must be signed and checked with `ReplayGuard`.
- PIN encryption is only for low-value data like Wi-Fi passwords, because a short PIN can be guessed from a recording.
- Key files from `keygen` are stored unencrypted in this prototype. The app will use Android Keystore.
- Payments use dummy money only. Real money needs RBI/NPCI approval and a bank partner.

## Roadmap

- [x] **Phase 1:** core engine (packet, crypto, error correction, modem, tests, benchmark)
- [ ] **Phase 2:** Flutter app with contact share, Wi-Fi share and offers
- [ ] **Phase 3:** offline payment (wallet, tokens, sync, double-spend check)
- [ ] **Phase 4:** attendance, tickets, door unlock, login/2FA
- [ ] **Phase 5:** file transfer, emergency broadcast, ESP32 sensor demo, faster modem
- [ ] **Phase 6:** auto fallback (sound / QR / BLE), real-device benchmarks, demo
