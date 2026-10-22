/* Host test: runs the firmware code on a PC and writes what the ESP32 would play.
 *
 *   zig cc -O2 -o sltx test/host_tx.c src/soundlink.c src/monocypher/monocypher.c src/monocypher/monocypher-ed25519.c -lm
 *   sltx out.wav [normal|fast|ultrasonic]
 *
 * Prints the packet as hex on stdout. tests/test_firmware.py checks it against
 * the Python engine and decodes the WAV.
 */
#include <stdio.h>
#include <string.h>

#include "../src/soundlink.h"

static void put16(FILE *f, unsigned v) { fputc(v & 0xFF, f); fputc((v >> 8) & 0xFF, f); }
static void put32(FILE *f, unsigned long v) { put16(f, v & 0xFFFF); put16(f, (v >> 16) & 0xFFFF); }

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s out.wav [profile]\n", argv[0]);
        return 2;
    }
    const sl_profile *p = &SL_PROFILE_NORMAL;
    if (argc > 2 && !strcmp(argv[2], "fast")) p = &SL_PROFILE_FAST;
    if (argc > 2 && !strcmp(argv[2], "ultrasonic")) p = &SL_PROFILE_ULTRASONIC;

    uint8_t seed[32];
    for (int i = 0; i < 32; i++) seed[i] = (uint8_t)(200 + i); /* fixed test key, never use for real */
    sl_device dev;
    sl_device_init(&dev, seed);

    const uint8_t kinds[3] = {SL_TEMPERATURE, SL_HUMIDITY, SL_BATTERY};
    const float values[3] = {31.25f, 64.5f, 87.0f};
    uint8_t payload[128], pkt[SL_MAX_PACKET], frame[SL_MAX_FRAME];
    size_t pl = sl_sensor_payload(&dev, "ESP32 room", kinds, values, 3, payload, sizeof payload);
    size_t n = sl_packet(&dev, SL_SENSOR, payload, pl, 0x0A0B0C0Du, 1800000000u, pkt);
    size_t fl = sl_frame(pkt, n, 0x1234, frame);
    if (!pl || !n || !fl) {
        fprintf(stderr, "build failed\n");
        return 1;
    }
    for (size_t i = 0; i < n; i++) printf("%02x", pkt[i]);
    printf("\n");

    sl_tx tx;
    sl_tx_begin(&tx, p, frame, fl, 0.6f);
    long total = sl_tx_total(&tx);
    FILE *f = fopen(argv[1], "wb");
    if (!f) return 1;
    fwrite("RIFF", 1, 4, f); put32(f, 36 + total * 2); fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 16); put16(f, 1); put16(f, 1); put32(f, SL_SAMPLE_RATE); put32(f, SL_SAMPLE_RATE * 2);
    put16(f, 2); put16(f, 16); fwrite("data", 1, 4, f); put32(f, total * 2);
    int16_t buf[256];
    size_t got;
    while ((got = sl_tx_read(&tx, buf, 256)) > 0)
        for (size_t i = 0; i < got; i++) put16(f, (unsigned)(uint16_t)buf[i]);
    fclose(f);
    return 0;
}
