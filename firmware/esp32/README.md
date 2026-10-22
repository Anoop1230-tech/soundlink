# SoundLink for ESP32

A transmit-only C port of the SoundLink engine. A cheap ESP32 with a speaker sends **signed** sensor readings that the SoundLink app (and `python -m soundlink listen`) can receive. It needs no Wi-Fi, no Bluetooth and no pairing.

| File | What it is |
|---|---|
| `src/soundlink.h/.c` | Packet + Ed25519 signature + CRC + Reed-Solomon + MFSK audio, plain C99 |
| `src/monocypher/` | [Monocypher 4.0.3](https://monocypher.org) (Ed25519, BSD-2 / CC0, unchanged) |
| `examples/SensorBeacon/` | Arduino sketch: plays a sensor report every 30 s through an I2S amp |
| `test/host_tx.c` | Runs the same code on a PC and writes a WAV, used by the tests |

Profiles: `SL_PROFILE_NORMAL`, `SL_PROFILE_FAST` and `SL_PROFILE_ULTRASONIC`. Turbo (OFDM) isn't ported yet. Audio is made 256 samples at a time with a float sine table, so it needs about 2 KB of RAM.

## Hardware

- ESP32 dev board (Arduino core 3.x)
- MAX98357A I2S amplifier + small speaker: BCLK → GPIO 26, LRC → GPIO 25, DIN → GPIO 22, VIN → 5V, GND → GND
- Optional: potentiometer / LDR on GPIO 34

## Build

1. Copy this `esp32` folder into `Documents/Arduino/libraries/` and rename it `SoundLink`.
2. Arduino IDE → File → Examples → SoundLink → SensorBeacon, then select your ESP32 board and upload.
3. Open the Serial Monitor (115200). It prints the device ID (public key).
4. On the phone: Settings → Normal mode → Receive → listen. A sensor card appears every 30 s.

## How it was tested

The ESP32 build itself has not been compiled or run here, because no ESP32 toolchain or board was available. The C code was compiled for the PC with `zig cc` (`core-engine/tests/test_firmware.py`, `pip install ziglang`):

- the packet bytes, signature included, are identical to what the Python engine builds with the same key
- its sound decodes in all three MFSK modes, and also through the simulated noisy room at 5 dB

## Notes

- The device key is created from the ESP32 hardware RNG on first boot and kept in NVS flash. Anyone who can read the flash can copy it, so turn on flash encryption for real deployments.
- A plain ESP32 has no clock, so it sends timestamp 0. Receivers that use `ReplayGuard` would reject these packets; sensor readings use the `seq` counter instead.
