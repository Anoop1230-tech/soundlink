# SoundLink

Send data between devices using sound. No internet, no Bluetooth, no pairing.

SoundLink is a secure, offline platform for sharing small pieces of data through a speaker and a microphone: payments, Wi-Fi passwords, contacts, attendance, tickets, door unlock, login, emergency alerts and more. Every feature uses the same core engine; only the data inside the packet changes.

> Status: **All 6 phases done.** See the [demo guide](docs/DEMO.md).
>
> Phase 5: Core engine (Python), Android app (Flutter), offline payments, attendance / tickets / doors / login, and now a **10x faster turbo mode**, **file sharing**, **emergency alerts** and an **ESP32 sensor** that talks to the app.

## Project layout

| Folder | What's inside |
|---|---|
| `core-engine/` | Python engine and command line tool (see below) |
| `mobile-app/` | Flutter Android app with a Dart copy of the engine ([README](mobile-app/README.md)) |
| `backend/` | SoundBank, a demo bank server for offline payments and the login demo site (FastAPI + SQLite) |
| `firmware/esp32/` | C library + Arduino sketch: an ESP32 with a speaker sends signed sensor readings ([README](firmware/esp32/README.md)) |

## Offline payments (demo money)

```
 ONLINE   phone ── load Rs 300 ──► bank signs a certificate: "this wallet may spend Rs 300"
 OFFLINE  shop  ── request Rs 20 (signed) ──────────► customer
          shop  ◄── payment (signed by wallet, carries the bank certificate) ── customer
          shop  ── receipt (signed) ─────────────────► customer
 ONLINE   shop  ── sync ──► bank settles and checks for double spending
```

- The shop checks everything **offline** with only the bank's public key: the bank certificate, the wallet signature, the amount, and that the payment answers its own request (so an old recorded payment can't be played again).
- The phone saves "money spent" **before** it plays the payment, so a crash can't create money.
- Each payment has a number (counter) and a running total. If someone copies their wallet file and spends the same money twice, the two payments share a number. The same shop refuses it on the spot; a different shop finds out when it syncs. The bank still pays the shop, freezes the cheater and takes the money back.
- Limits: Rs 500 per payment, Rs 2000 in the offline wallet, certificate valid 30 days.
- Formats are in `core-engine/soundlink/payment.py`. A payment is 104 bytes and fits in one sound frame.

```powershell
cd backend
pip install -e .
python -m soundbank demo                 # whole story in a fake room, no mic needed
python -m soundbank serve                # run the bank for the phones (port 8000)
python -m soundbank register "Anoop"     # laptop wallet: Rs 1000 demo money
python -m soundbank load 300
python -m soundbank request 20 --note tea    # act as the shop
python -m soundbank pay                      # act as the customer
python -m soundbank sync
```

In the app: **Wallet** tab → enter the bank address (the laptop's Wi-Fi IP, e.g. `http://192.168.1.10:8000`) → Load → **Pay** or **Request money**.

Not safe for real money: the bank runs over plain http on the local network, anyone who can reach it can create accounts with fake money, and the phone's wallet is protected only by app storage (a real system would use a secure hardware counter). Real money also needs RBI/NPCI approval and a bank partner.

## Attendance, tickets, doors and login

All four use the same trick: one side plays a **fresh random challenge**, the phone answers with a reply **signed by its own key** that includes the challenge. A recording of an old reply is useless. Formats are in `core-engine/soundlink/access.py`; the app has them on the **Access** tab.

| Feature | How it works | What it stops |
|---|---|---|
| **Attendance** | Teacher plays a code that changes every 10 s (HMAC of a secret). Students' phones answer with the code + their name; teacher's phone confirms. List can be copied as CSV. | Proxy attendance: a code sent to a friend outside is stale in 30 s; one phone counts once |
| **Tickets** | Organizer signs a ticket tied to the guest's phone key. At the gate, the gate plays a challenge, the phone answers with the ticket signed by the same key. Works offline. | Screenshots and forwarded tickets (wrong key), using a ticket twice |
| **Door unlock** | Door (a phone, laptop, or later an ESP32) plays a challenge; allowed phones sign it. People ask to be added; the door owner taps Allow. | Replaying a recorded "open" sound, unknown phones |
| **Login / 2FA** | Website plays a login challenge from the laptop speaker; the phone shows "Log in as anoop?" and sends a signed approval to the site. The first phone that approves a username is linked to it. | Passwords, and logging in from somewhere that can't hear the laptop |

```powershell
# laptop as teacher / door (needs a working mic)
python -m soundlink teach "DBMS lecture"        # saves attendance-<date>.csv on Ctrl+C
python -m soundlink door "Lab 3"

# login demo website
cd backend
python -m soundbank serve
# open http://<laptop-ip>:8000/site in the laptop browser, then on the phone: Access -> Log in to a website
```

Limits: the login site is a demo (no real accounts, plain http). Tickets and doors trust the organizer's / door's phone; losing that phone means making a new event or door.

## How it works

```
 data ─► packet (type, id, time) ─► compress ─► encrypt ─► sign ─► CRC
      ─► split into frames ─► Reed-Solomon ─► MFSK tones ─► speaker

 mic ─► band-pass filter ─► find chirp ─► read tones ─► Reed-Solomon
     ─► join frames ─► CRC ─► check signature ─► decrypt ─► replay check ─► data
```

| Part | What it does |
|---|---|
| `packet.py` | Common packet format for every feature, plus compression, encryption (XChaCha20-Poly1305), Ed25519 signature, CRC-16 and replay protection |
| `modem.py` | Our own multi-tone FSK modem: chirp preamble for timing, 4 tone groups x 16 tones, tone rotation, streaming decoder |
| `fec.py` | Reed-Solomon error correction that uses tone confidence to fix up to 2x more errors |
| `transport.py` | Splits big packets into frames and puts them back together |
| `modules.py` | Small binary formats for contact, Wi-Fi and offer (much smaller than JSON) |
| `link.py` | Simple API: `SoundLink.encode(packet)` and `Receiver.feed(mic_audio)` |
| `sim.py` | Fake room (echo, noise, clock drift) for testing without a speaker |

The Flutter app has the same engine in Dart (`mobile-app/lib/engine`). Tests check that both make exactly the same bytes and can decode each other's sound.

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
| `turbo` | 2.0-6.5 kHz, OFDM (96 tones at once) | files and long messages, phones close together |

## Benchmark (simulated room with echo and clock drift)

`python -m soundlink bench --trials 6 --snr 20 10 5 3`

| Profile | 200-byte message | Speed | Success at 3 dB noise |
|---|---|---|---|
| normal | 11.0 s | 18 B/s | 100% |
| fast | 5.8 s | 34 B/s | 100% |
| ultrasonic | 19.0 s | 10.5 B/s | 100% |
| turbo | 1.1 s | 178 B/s (286 B/s at 900 bytes) | needs about 15 dB or better |

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

# share the same things the app shares (add --out file.wav to save instead of playing)
python -m soundlink share contact --name "Asha" --phone "+91 90000 00000"
python -m soundlink share wifi --ssid Home --password secret123 --pin 1234
python -m soundlink share offer --title "20% off" --shop "City Pharmacy" --days 7 --profile ultrasonic
```

## Mobile app

```powershell
cd mobile-app
flutter test
flutter build apk --release   # build\app\outputs\flutter-apk\app-release.apk
```

Install the APK on two Android phones (or one phone + a laptop running `python -m soundlink listen`), pick the same sound mode on both, and send.

## Security notes

- Anyone nearby can record the sound, so anything that does an action (payment, door unlock, attendance) must be signed and checked with `ReplayGuard`.
- PIN encryption is only for low-value data like Wi-Fi passwords, because a short PIN can be guessed from a recording.
- Key files from `keygen` are stored unencrypted in this prototype. The app keeps its key in Android Keystore-backed secure storage.
- Payments use dummy money only. Real money needs RBI/NPCI approval and a bank partner.

## Turbo mode, files, alerts and sensors (Phase 5)

**Turbo** uses OFDM: 96 tones play at the same time and each one carries 2 bits in the change of its phase (DQPSK), with a cyclic prefix that soaks up room echo. It sends 900 bytes in 3.1 s, where `fast` needs 18 s, but it needs a cleaner channel, so the phones should be close.

| Feature | How it works |
|---|---|
| **Files** | Small files (up to 1.5 KB, or 3.9 KB in turbo) go inside the sound. Bigger files: the sender serves the file from a tiny web server on the local Wi-Fi at a random secret address, and only the link, size and SHA-256 go by sound. The receiver checks the checksum before saving, and file names are cleaned so they can't escape the download folder. |
| **Emergency alerts** | Signed alert with severity, type, area and end time (works in Hindi and other scripts). Phones show **VERIFIED** only if the sender is in their trusted list; anyone can play a sound, so unknown senders get a clear warning instead. A WAV can be played through a loudspeaker or FM radio. |
| **Sensors** | Signed readings (temperature, BP, SpO2, PM2.5, …) with a counter. The ESP32 library sends them with just a speaker. |

```powershell
python -m soundlink alert "Flood warning" "Move to higher ground" --severity danger --kind flood --area "Ward 12" --key-file gov.key
python -m soundlink alert "Cyclone" --out cyclone.wav       # for a loudspeaker / radio
python -m soundlink sendfile notes.pdf                      # big file: link by sound, file over Wi-Fi
python -m soundlink sendfile photo.jpg --inline --profile turbo
python -m soundlink getfile --folder received
python -m soundlink bench --profiles fast turbo
```

In the app, **Send** has new **File** and **Emergency alert** options, the **Receive** tab shows alert, sensor and file cards, and **Settings** has the turbo mode and the list of trusted alert senders.

## Fallback and real-device testing (Phase 6)

- **QR fallback:** any packet can be shown as QR codes (`SL1:` + base64 of one chunk, 400 bytes per code) and scanned with the camera. Big packets cycle through several codes. Scanned chunks go into the same receiver as sound, so CRC, signature, decryption and replay checks are unchanged. In the app, tap the **QR** icon in the top bar of any screen: *Show last sent as QR* or *Scan a QR code*.
- **Bluetooth / Wi-Fi nearby:** sends the same signed packet with Google Nearby Connections (no internet), from the same menu.
- **Sound test:** the speedometer icon opens a two-phone test that plays numbered packets and reports % received, signal quality and bytes fixed by error correction, with **Copy CSV** for your report. Laptop version: `python -m soundlink testsend` / `testrecv`.

```powershell
python -m soundlink qr "hello"                 # QR in the terminal (or --out hello.png)
python -m soundlink testsend --count 10 --profile fast
python -m soundlink testrecv --profile fast
```

## Roadmap

- [x] **Phase 1:** core engine (packet, crypto, error correction, modem, tests, benchmark)
- [x] **Phase 2:** Flutter app with contact share, Wi-Fi share and offers
- [x] **Phase 3:** offline payment (wallet, bank certificates, sync, double-spend check)
- [x] **Phase 4:** attendance, tickets, door unlock, login/2FA
- [x] **Phase 5:** file transfer, emergency broadcast, ESP32 sensor demo, faster (turbo OFDM) modem
- [x] **Phase 6:** fallback (QR / Bluetooth), real-device test screen, demo guide
