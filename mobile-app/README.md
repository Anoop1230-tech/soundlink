# SoundLink mobile app

Flutter app (Android) that sends and receives contacts, Wi-Fi networks, offers and text through sound.

## Screens

- **Receive:** tap the big button to listen. Received items appear as cards with actions: save a contact (opens the phone's "new contact" screen), connect to Wi-Fi (Android asks to save the network), or copy a coupon code. PIN-locked items show an **Unlock** button.
- **Send:** pick contact, Wi-Fi, offer or text, fill the form and tap **Send by sound**. Wi-Fi is PIN-locked by default.
- **History:** everything sent and received on this phone.
- **Settings:** sound mode (normal / fast / ultrasonic), volume, how many times to repeat, and this device's ID.

Both phones must use the same sound mode.

## How it is built

```
lib/
  engine/     Dart port of core-engine (packet, crypto, Reed-Solomon, modem, chunks, modules)
  services/   mic + speaker (record, audioplayers), secure key storage, history, actions
  ui/         screens
test/
  engine_test.dart    engine in a fake noisy room
  interop_test.dart   checks Dart against Python: same bytes, same keys, decodes Python's WAVs
  fixtures/           made by core-engine/tools/make_fixtures.py
```

- The device signing key is created on first launch and kept in `flutter_secure_storage` (Android Keystore).
- The mic is opened in "unprocessed" mode with echo cancel, noise suppression and auto gain turned off, because voice processing removes our tones.
- Sound is played as a 48 kHz WAV so Android doesn't compress it.
- Permissions: microphone (only while listening) and Wi-Fi state (to add a received network). Location is removed from the manifest because adding a network doesn't need it.

## Build and run

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release      # build\app\outputs\flutter-apk\app-release.apk
flutter install                  # with a phone connected over USB (USB debugging on)
```

The release APK is signed with the debug key for now, which is fine for testing but not for the Play Store.

If you change the engine on the Python side, regenerate the fixtures so both sides stay in sync:

```powershell
cd ..\core-engine
python tools\make_fixtures.py ..\mobile-app\test\fixtures
```

## Tips for testing on phones

- Start with the **Normal** mode, phones 10-50 cm apart, media volume high.
- If nothing is received, check the mic level bar on the Receive screen.
- **Ultrasonic** is almost silent but many phone speakers and mics are weak above 18 kHz, so it may only work at short range.
- A laptop can be one side: `python -m soundlink listen` or `python -m soundlink share wifi --ssid Home --password secret --pin 1234`.
