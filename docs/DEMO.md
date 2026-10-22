# SoundLink demo guide

A 10-minute live demo for judges, interviewers or a viva. You need:

- 2 Android phones with `app-release.apk` installed (Settings → Install unknown apps)
- 1 laptop with Python (for the bank, the login website and the attack demo), on the same Wi-Fi as the phones
- Optional: an ESP32 + MAX98357A + speaker running the `SensorBeacon` sketch

Before you start, on both phones open **Settings** and pick **Normal** mode with volume around 80%. Hold the phones 10–50 cm apart. In a noisy hall, use the **QR** button at the top instead (see step 7).

## 0. Setup (before the demo)

```powershell
cd soundlink\core-engine;  pip install -e .
cd ..\backend;             pip install -e .
python -m soundbank serve                 # leave running; note the laptop IP, e.g. 192.168.1.10
```

On both phones: **Wallet** → bank address `http://192.168.1.10:8000` → names "Asha" and "Chai Shop" → **Load** Rs 300 on Asha.

## 1. The problem (30 s)

"Payments, tickets, attendance and sharing all assume internet or special hardware like NFC. SoundLink uses only a speaker and a microphone, which every phone and many cheap devices have, and everything it sends is signed, so you can't fake it."

## 2. Share a contact (1 min)

Phone A: **Send → Contact card → Send by sound**. Phone B: **Receive → tap to listen**. A contact card appears; tap **Save**.

Point out: "From …" is the sender's device ID. The data is signed, and only about 60 bytes went over the sound.

## 3. Wi-Fi with a PIN (1 min)

Phone A: **Send → Wi-Fi network** (PIN is on by default). Phone B shows **Locked Wi-Fi → Unlock** → enter the PIN → **Connect**.

Point out: "Anyone nearby can record sound, so secrets are encrypted (XChaCha20-Poly1305)."

## 4. Offline payment and catching a cheat (3 min)

Turn **mobile data and Wi-Fi off** on both phones.

- Chai Shop: **Wallet → Request money → Rs 20 → Ask for payment**
- Asha: **Wallet → Pay** → "Pay Rs 20?" → **Pay**. The shop shows "Received", Asha hears the receipt.
- Turn Wi-Fi back on. Chai Shop: **Sync**, and the bank balance goes up.

Show the cheating case on the laptop (it uses the same code as the phones):

```powershell
cd backend; python -m soundbank demo
```

It prints the whole story: a wallet copied before paying, the same shop refusing the replay offline, another shop being fooled offline, and then on sync the bank pays both shops, **freezes** the cheater and takes back the extra money.

## 5. Proxy-proof attendance (1 min)

Teacher phone: **Access → Take attendance → "DBMS" → Start class**. Student phone: **Access → I'm a student → Mark me present**. The name appears on the teacher's list. Copy the CSV.

Point out: the code changes every 10 s, so a code forwarded to a friend outside is useless 30 s later.

## 6. Passwordless login (1 min)

On the laptop browser, open `http://192.168.1.10:8000/site`, enter a username and click **Log in with SoundLink**; the laptop plays a sound. Phone: **Access → Log in to a website → Listen** → **Approve**. The page shows "Logged in".

## 7. When sound fails: QR and Bluetooth (1 min)

After any send, tap the **QR icon** in the top bar → **Show last sent as QR**. On the other phone: QR icon → **Scan a QR code**. Same packet, same checks (CRC + signature). Big packets cycle through several QR codes automatically.

**Bluetooth / Wi-Fi nearby** does the same without the camera (open that page on both phones: Send / Receive).

## 8. Real numbers (show the test screen)

Speedometer icon → **Sound test**. One phone **Receive test**, the other **Send test** (10 packets). Repeat at 30 cm / 1 m / 3 m and in each mode, then **Copy CSV** into your report.

| Mode | Simulator speed | Notes |
|---|---|---|
| normal | 18 B/s | works in noise down to 3 dB SNR (simulated) |
| fast | 34 B/s | quiet rooms |
| ultrasonic | 10 B/s | almost silent, short range on many phones |
| turbo | ~290 B/s | files; phones close together |

The simulator numbers come from `python -m soundlink bench`. Fill in your own real-phone results from the test screen. Don't present simulator numbers as real-device numbers.

## 9. Emergency alert and ESP32 (optional, 1 min)

```powershell
python -m soundlink keygen gov.key
python -m soundlink alert "Flood warning" "Move to higher ground" --severity danger --kind flood --key-file gov.key
```

The phone shows a red **NOT VERIFIED** alert. Tap **Trust sender** and play it again; it now shows **VERIFIED**. The ESP32 beacon shows up as a sensor card every 30 s.

## Questions you may be asked

- **"Can someone record the sound and replay it?"** Payments answer a one-time request nonce; doors, tickets and login answer a fresh challenge; attendance codes expire in 30 s. A replay fails each check (there are tests for every case).
- **"What if the payer's phone is offline forever?"** The shop can still sync the signed payment, because the bank guarantees certificates it issued. Limits are Rs 500 per payment and Rs 2000 per wallet.
- **"Is this real money?"** No, it's demo money. Real money needs RBI/NPCI approval, a bank partner, and a hardware-backed counter on the phone.
- **"Why not just QR?"** QR is included as a fallback. Sound works one-to-many (a teacher to a whole class, a loudspeaker for alerts), needs no camera, and works with a buzzer on a ₹300 device.
