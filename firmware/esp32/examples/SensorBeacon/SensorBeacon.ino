/*
 * SoundLink sensor beacon for ESP32 (Arduino core 3.x).
 *
 * Every 30 s it plays a signed sensor report through an I2S amplifier
 * (MAX98357A) and speaker. Phones running the SoundLink app on the
 * Receive tab ("Normal" mode) show it as a sensor card.
 *
 * Wiring (MAX98357A):  BCLK -> GPIO 26, LRC -> GPIO 25, DIN -> GPIO 22,
 *                      VIN -> 5V, GND -> GND, speaker on the + / - pins.
 * Readings: chip temperature, and an analog value on GPIO 34 (e.g. a
 * potentiometer or LDR). Replace read_sensors() with your own sensor.
 *
 * On first boot a random device key is made and kept in flash (NVS).
 * The public key is printed on Serial; it is the device's ID.
 */
#include <Arduino.h>
#include <ESP_I2S.h>
#include <Preferences.h>
#include <soundlink.h>

#define PIN_BCLK 26
#define PIN_LRC 25
#define PIN_DOUT 22
#define PIN_ANALOG 34
#define INTERVAL_MS 30000

static I2SClass i2s;
static sl_device dev;
static Preferences prefs;

static void load_key() {
  uint8_t seed[32];
  prefs.begin("soundlink", false);
  if (prefs.getBytes("seed", seed, 32) != 32) {
    esp_fill_random(seed, 32);  // hardware RNG
    prefs.putBytes("seed", seed, 32);
  }
  prefs.end();
  sl_device_init(&dev, seed);
  memset(seed, 0, sizeof seed);
  Serial.print("SoundLink device ID (public key): ");
  for (int i = 0; i < 32; i++) Serial.printf("%02x", dev.public_key[i]);
  Serial.println();
}

static int read_sensors(uint8_t *kinds, float *values) {
  kinds[0] = SL_TEMPERATURE;
  values[0] = temperatureRead();  // chip temperature, °C
  kinds[1] = SL_VALUE;
  values[1] = analogRead(PIN_ANALOG) * 100.0f / 4095.0f;  // 0..100
  return 2;
}

static void play_packet(const uint8_t *pkt, size_t n) {
  uint8_t frame[SL_MAX_FRAME];
  size_t fl = sl_frame(pkt, n, (uint16_t)esp_random(), frame);
  sl_tx tx;
  if (!fl || sl_tx_begin(&tx, &SL_PROFILE_NORMAL, frame, fl, 0.6f) != 0) return;
  static int16_t buf[256];
  size_t got;
  while ((got = sl_tx_read(&tx, buf, 256)) > 0) i2s.write((uint8_t *)buf, got * sizeof(int16_t));
  memset(buf, 0, sizeof buf);
  for (int i = 0; i < 40; i++) i2s.write((uint8_t *)buf, sizeof buf);  // short silence so the amp doesn't click
}

void setup() {
  Serial.begin(115200);
  delay(500);
  load_key();
  i2s.setPins(PIN_BCLK, PIN_LRC, PIN_DOUT);
  if (!i2s.begin(I2S_MODE_STD, SL_SAMPLE_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) {
    Serial.println("I2S failed to start, check the wiring");
  }
}

void loop() {
  uint8_t kinds[16], payload[128], pkt[SL_MAX_PACKET];
  float values[16];
  int n = read_sensors(kinds, values);
  size_t pl = sl_sensor_payload(&dev, "ESP32 sensor", kinds, values, n, payload, sizeof payload);
  // No real clock on a plain ESP32: time 0. Use NTP or an RTC if you have one.
  size_t len = sl_packet(&dev, SL_SENSOR, payload, pl, esp_random(), 0, pkt);
  if (len) {
    Serial.printf("reading #%lu: %.2f C, %.1f\n", (unsigned long)dev.seq, values[0], values[1]);
    play_packet(pkt, len);
  }
  delay(INTERVAL_MS);
}
