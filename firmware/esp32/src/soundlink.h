/*
 * SoundLink transmitter for small devices (ESP32, or any C99 machine).
 *
 * Builds signed SoundLink packets and turns them into MFSK audio samples,
 * byte-for-byte compatible with core-engine/soundlink (Python) and the app.
 * Transmit only: a buzzer / speaker is enough, no microphone needed.
 *
 *   sl_device dev;  sl_device_init(&dev, seed32);
 *   uint8_t pkt[SL_MAX_PACKET]; size_t n = sl_sensor_packet(&dev, ...);
 *   uint8_t fr[SL_MAX_FRAME]; size_t f = sl_frame(pkt, n, random16, fr);
 *   sl_tx tx; sl_tx_begin(&tx, &SL_PROFILE_NORMAL, fr, f, 0.6f);
 *   int16_t buf[256]; size_t got;
 *   while ((got = sl_tx_read(&tx, buf, 256)) > 0) i2s_write(buf, got);
 *
 * Audio is generated in small blocks, so it needs only ~2 KB of RAM.
 */
#ifndef SOUNDLINK_H
#define SOUNDLINK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SL_SAMPLE_RATE 48000
#define SL_MAX_FRAME 240   /* bytes of packet per sound frame */
#define SL_MAX_PACKET 236  /* this library sends one frame per packet */

/* Packet types (same numbers as packet.py) */
enum {
    SL_TEXT = 0x00, SL_DOOR_UNLOCK = 0x22, SL_EMERGENCY = 0x40, SL_OFFER = 0x50, SL_SENSOR = 0x60
};

/* Sensor kinds (same numbers as extras.py) */
enum {
    SL_TEMPERATURE = 1, SL_HUMIDITY = 2, SL_HEART_RATE = 3, SL_SPO2 = 4, SL_BP_SYS = 5, SL_BP_DIA = 6,
    SL_GLUCOSE = 7, SL_BATTERY = 8, SL_PM25 = 9, SL_WEIGHT = 10, SL_DOOR_OPEN = 11, SL_VALUE = 12
};

typedef struct {
    const char *name;
    float base_freq, spacing;
    int groups;         /* 16-tone groups playing together */
    int symbol_len;     /* samples per symbol */
    int nsym;           /* Reed-Solomon parity bytes per block */
    int preamble_len, gap_len, tail_len;
} sl_profile;

extern const sl_profile SL_PROFILE_NORMAL, SL_PROFILE_FAST, SL_PROFILE_ULTRASONIC;

typedef struct {
    uint8_t seed[32];        /* keep secret: this is the device's private key */
    uint8_t public_key[32];
    uint32_t seq;            /* sensor reading counter */
} sl_device;

/* ---- packets ---- */
void sl_device_init(sl_device *dev, const uint8_t seed[32]);
/* Build a signed packet. time_s = unix time (0 if the device has no clock),
   msg_id should be random. Returns length or 0 on error. */
size_t sl_packet(const sl_device *dev, uint8_t type, const uint8_t *payload, size_t len, uint32_t msg_id,
                 uint32_t time_s, uint8_t out[SL_MAX_PACKET]);
/* Sensor report payload (extras.SensorReport). kinds/values have n items, values in real units. */
size_t sl_sensor_payload(sl_device *dev, const char *name, const uint8_t *kinds, const float *values, int n,
                         uint8_t *out, size_t cap);

/* Wrap a packet into one sound frame (adds the 4-byte chunk header the receiver
   expects: transfer_id, part 0 of 1). Returns frame length or 0. */
size_t sl_frame(const uint8_t *packet, size_t len, uint16_t transfer_id, uint8_t out[SL_MAX_FRAME]);

/* ---- helpers shared with the tests ---- */
uint16_t sl_crc16(const uint8_t *data, size_t len);
size_t sl_rs_encode(const uint8_t *data, size_t len, int nsym, uint8_t *out); /* one block, len+nsym <= 255 */

/* ---- audio ---- */
typedef struct {
    const sl_profile *p;
    float volume;
    uint8_t len_block[8];          /* 2 + 6 RS */
    uint8_t body[SL_MAX_FRAME + 64];
    int body_len;
    long pos, total;               /* samples */
    int len_syms, body_syms;
} sl_tx;

int sl_tx_begin(sl_tx *tx, const sl_profile *p, const uint8_t *frame, size_t len, float volume);
long sl_tx_total(const sl_tx *tx);
/* Fill up to n samples; returns how many were written (0 = done). */
size_t sl_tx_read(sl_tx *tx, int16_t *out, size_t n);

#ifdef __cplusplus
}
#endif
#endif
