/* SoundLink transmitter, see soundlink.h. Matches core-engine/soundlink byte for byte. */
#include "soundlink.h"

#include <math.h>
#include <string.h>

#include "monocypher/monocypher-ed25519.h"
#include "monocypher/monocypher.h"

#define TONES 16
#define LEN_NSYM 6
#define SL_PI 3.14159265358979323846

const sl_profile SL_PROFILE_NORMAL = {"normal", 1500.0f, 62.5f, 4, 2304, 32, 7680, 1440, 2400};
const sl_profile SL_PROFILE_FAST = {"fast", 1500.0f, 125.0f, 4, 1152, 32, 7680, 1440, 2400};
const sl_profile SL_PROFILE_ULTRASONIC = {"ultrasonic", 18000.0f, 62.5f, 2, 2304, 16, 7680, 1440, 2400};

/* ---------------------------------------------------------------- CRC-16/CCITT-FALSE */

uint16_t sl_crc16(const uint8_t *d, size_t n) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < n; i++) {
        crc ^= (uint16_t)d[i] << 8;
        for (int b = 0; b < 8; b++) crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
    }
    return crc;
}

/* ---------------------------------------------------------------- Reed-Solomon, GF(2^8) 0x11d, fcr 0 */

static uint8_t gf_exp[512], gf_log[256];
static int gf_ready = 0;

static void gf_init(void) {
    if (gf_ready) return;
    int x = 1;
    for (int i = 0; i < 255; i++) {
        gf_exp[i] = (uint8_t)x;
        gf_log[x] = (uint8_t)i;
        x <<= 1;
        if (x & 0x100) x ^= 0x11d;
    }
    for (int i = 255; i < 512; i++) gf_exp[i] = gf_exp[i - 255];
    gf_ready = 1;
}

static uint8_t gf_mul(uint8_t a, uint8_t b) { return (a && b) ? gf_exp[gf_log[a] + gf_log[b]] : 0; }

/* Encode one block (len + nsym <= 255). out = data followed by nsym parity bytes. */
size_t sl_rs_encode(const uint8_t *data, size_t len, int nsym, uint8_t *out) {
    uint8_t gen[65];
    gf_init();
    if (nsym > 64 || len + (size_t)nsym > 255) return 0;
    /* generator = prod (x - a^i), stored highest power first like reedsolo */
    int glen = 1;
    gen[0] = 1;
    for (int i = 0; i < nsym; i++) {
        uint8_t root = gf_exp[i];
        gen[glen] = 0;
        for (int j = glen; j > 0; j--) gen[j] ^= gf_mul(gen[j - 1], root);
        glen++;
    }
    memcpy(out, data, len);
    memset(out + len, 0, (size_t)nsym);
    for (size_t i = 0; i < len; i++) {
        uint8_t coef = out[i];
        if (!coef) continue;
        for (int j = 1; j < glen; j++) out[i + (size_t)j] ^= gf_mul(gen[j], coef);
    }
    memcpy(out, data, len);
    return len + (size_t)nsym;
}

/* Multi-block like fec.encode: data split into (255 - nsym) byte blocks. */
static size_t rs_encode_all(const uint8_t *data, size_t len, int nsym, uint8_t *out) {
    size_t k = 255 - (size_t)nsym, o = 0;
    for (size_t i = 0; i < len; i += k) {
        size_t n = (len - i < k) ? len - i : k;
        o += sl_rs_encode(data + i, n, nsym, out + o);
    }
    return o;
}

/* ---------------------------------------------------------------- packets */

void sl_device_init(sl_device *dev, const uint8_t seed[32]) {
    uint8_t s[32], secret[64];
    memcpy(s, seed, 32);
    memcpy(dev->seed, seed, 32);
    crypto_ed25519_key_pair(secret, dev->public_key, s); /* wipes s */
    crypto_wipe(secret, sizeof secret);
    dev->seq = 0;
}

static void put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}

size_t sl_packet(const sl_device *dev, uint8_t type, const uint8_t *payload, size_t len, uint32_t msg_id,
                 uint32_t time_s, uint8_t out[SL_MAX_PACKET]) {
    /* header(11) + body + pub(32) + sig(64) + crc(2); never compressed, never encrypted */
    if (11 + len + 32 + 64 + 2 > SL_MAX_PACKET) return 0;
    out[0] = 1; out[1] = type; out[2] = 0x04; /* SIGNED */
    put32(out + 3, msg_id);
    put32(out + 7, time_s);
    memcpy(out + 11, payload, len);
    size_t n = 11 + len;
    memcpy(out + n, dev->public_key, 32);
    n += 32;
    uint8_t s[32], secret[64], pub[32];
    memcpy(s, dev->seed, 32);
    crypto_ed25519_key_pair(secret, pub, s);
    crypto_ed25519_sign(out + n, secret, out, n);
    crypto_wipe(secret, sizeof secret);
    n += 64;
    uint16_t crc = sl_crc16(out, n);
    out[n++] = (uint8_t)(crc >> 8);
    out[n++] = (uint8_t)crc;
    return n;
}

size_t sl_sensor_payload(sl_device *dev, const char *name, const uint8_t *kinds, const float *values, int n,
                         uint8_t *out, size_t cap) {
    size_t nl = strlen(name);
    if (nl > 40 || n < 1 || n > 16) return 0;
    size_t need = 4 + 1 + nl + 1 + 5 * (size_t)n;
    if (need > cap) return 0;
    dev->seq++;
    put32(out, dev->seq);
    out[4] = (uint8_t)nl;
    memcpy(out + 5, name, nl);
    size_t i = 5 + nl;
    out[i++] = (uint8_t)n;
    for (int k = 0; k < n; k++) {
        out[i++] = kinds[k];
        put32(out + i, (uint32_t)(int32_t)lround((double)values[k] * 100.0));
        i += 4;
    }
    return i;
}

size_t sl_frame(const uint8_t *packet, size_t len, uint16_t transfer_id, uint8_t out[SL_MAX_FRAME]) {
    if (len == 0 || len + 4 > SL_MAX_FRAME) return 0;
    out[0] = (uint8_t)(transfer_id >> 8);
    out[1] = (uint8_t)transfer_id;
    out[2] = 0; /* part 0 */
    out[3] = 1; /* of 1 */
    memcpy(out + 4, packet, len);
    return len + 4;
}

/* ---------------------------------------------------------------- audio (MFSK) */

static int symbols_for(int nbytes, int groups) { return (nbytes * 2 + groups - 1) / groups; }

int sl_tx_begin(sl_tx *tx, const sl_profile *p, const uint8_t *frame, size_t len, float volume) {
    if (len == 0 || len > SL_MAX_FRAME) return -1;
    uint8_t lb[2] = {(uint8_t)(len >> 8), (uint8_t)len};
    tx->p = p;
    tx->volume = volume;
    sl_rs_encode(lb, 2, LEN_NSYM, tx->len_block);
    tx->body_len = (int)rs_encode_all(frame, len, p->nsym, tx->body);
    tx->len_syms = symbols_for(2 + LEN_NSYM, p->groups);
    tx->body_syms = symbols_for(tx->body_len, p->groups);
    tx->pos = 0;
    tx->total = p->preamble_len + p->gap_len + (long)(tx->len_syms + tx->body_syms) * p->symbol_len + p->tail_len;
    return 0;
}

long sl_tx_total(const sl_tx *tx) { return tx->total; }

static int nibble(const uint8_t *b, int nbytes, int idx) {
    if (idx >= nbytes * 2) return 0;
    return (idx & 1) ? (b[idx / 2] & 0x0F) : (b[idx / 2] >> 4);
}

/* Sine from a table with linear interpolation, phase in cycles (0..1).
   Float only: the ESP32 has a single-precision FPU, double math would be far too slow for 48 kHz. */
#define SIN_N 1024
static float sin_tab[SIN_N + 1];
static int sin_ready = 0;

static void sin_init(void) {
    if (sin_ready) return;
    for (int i = 0; i <= SIN_N; i++) sin_tab[i] = (float)sin(2 * SL_PI * i / SIN_N);
    sin_ready = 1;
}

static float sin_cycles(float ph) {
    ph -= floorf(ph);
    float x = ph * SIN_N;
    int i = (int)x;
    if (i >= SIN_N) i = SIN_N - 1;
    float f = x - (float)i;
    return sin_tab[i] + (sin_tab[i + 1] - sin_tab[i]) * f;
}

static float chirp_sample(const sl_profile *p, long i) {
    const float sr = (float)SL_SAMPLE_RATE, t = (float)i / sr, dur = (float)p->preamble_len / sr;
    const float low = p->base_freq, high = p->base_freq + p->spacing * (float)(p->groups * TONES - 1);
    const float f0 = low - p->spacing, f1 = high + p->spacing;
    float v = sin_cycles(f0 * t + (f1 - f0) / (2 * dur) * t * t);
    long n = p->preamble_len, taper = n / 20;
    if (taper < 1) taper = 1;
    if (i < taper) v *= (taper == 1) ? 0.0f : (float)i / (float)(taper - 1);
    else if (i >= n - taper) v *= (taper == 1) ? 0.0f : 1.0f - (float)(i - (n - taper)) / (float)(taper - 1);
    return v;
}

static float symbol_sample(const sl_profile *p, const uint8_t *block, int nbytes, int s, int i) {
    int L = p->symbol_len, fade = (int)(0.05 * L);
    if (fade < 1) fade = 1;
    float env = 1.0f;
    if (i < fade) env = (fade == 1) ? 0.0f : (float)i / (float)(fade - 1);
    else if (i >= L - fade) env = (fade == 1) ? 0.0f : 1.0f - (float)(i - (L - fade)) / (float)(fade - 1);
    float acc = 0.0f, t = (float)i / (float)SL_SAMPLE_RATE;
    for (int g = 0; g < p->groups; g++) {
        int v = nibble(block, nbytes, s * p->groups + g);
        int tone = (v + 7 * s + 5 * g) % TONES; /* same rotation as modem._rotate */
        float f = p->base_freq + p->spacing * (float)(g * TONES + tone);
        acc += sin_cycles(f * t);
    }
    return acc * env / (float)p->groups;
}

size_t sl_tx_read(sl_tx *tx, int16_t *out, size_t n) {
    const sl_profile *p = tx->p;
    size_t k = 0;
    long a = p->preamble_len, b = a + p->gap_len, c = b + (long)tx->len_syms * p->symbol_len,
         d = c + (long)tx->body_syms * p->symbol_len;
    sin_init();
    for (; k < n && tx->pos < tx->total; k++, tx->pos++) {
        long i = tx->pos;
        float v = 0.0f;
        if (i < a) v = chirp_sample(p, i);
        else if (i >= b && i < c) v = symbol_sample(p, tx->len_block, 2 + LEN_NSYM, (int)((i - b) / p->symbol_len), (int)((i - b) % p->symbol_len));
        else if (i >= c && i < d) v = symbol_sample(p, tx->body, tx->body_len, (int)((i - c) / p->symbol_len), (int)((i - c) % p->symbol_len));
        v *= tx->volume;
        if (v > 1.0f) v = 1.0f;
        if (v < -1.0f) v = -1.0f;
        out[k] = (int16_t)(v * 32767.0f);
    }
    return k;
}
