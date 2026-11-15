#include "wifi_crypto.h"
#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <CommonCrypto/CommonSymmetricKeywrap.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void wpa_pmk(const char *pass, const u8 *ssid, size_t ssid_len, u8 pmk[32]) {
    CCKeyDerivationPBKDF(kCCPBKDF2, pass, strlen(pass), ssid, ssid_len,
                         kCCPRFHmacAlgSHA1, 4096, pmk, 32);
}

static void prf_sha1(const u8 *key, size_t key_len, const char *label,
                     const u8 *data, size_t data_len, u8 *out, size_t out_len) {
    size_t llen = strlen(label);
    u8 buf[256];
    memcpy(buf, label, llen);
    buf[llen] = 0;
    memcpy(buf + llen + 1, data, data_len);
    size_t mlen = llen + 1 + data_len;
    for (u8 i = 0; out_len > 0; i++) {
        buf[mlen] = i;
        u8 h[CC_SHA1_DIGEST_LENGTH];
        CCHmac(kCCHmacAlgSHA1, key, key_len, buf, mlen + 1, h);
        size_t n = out_len < sizeof h ? out_len : sizeof h;
        memcpy(out, h, n);
        out += n; out_len -= n;
    }
}

void wpa_ptk(const u8 pmk[32], const u8 aa[6], const u8 spa[6],
             const u8 anonce[32], const u8 snonce[32], u8 ptk[48]) {
    u8 d[76];
    bool a_first = memcmp(aa, spa, 6) < 0;
    memcpy(d, a_first ? aa : spa, 6);
    memcpy(d + 6, a_first ? spa : aa, 6);
    bool an_first = memcmp(anonce, snonce, 32) < 0;
    memcpy(d + 12, an_first ? anonce : snonce, 32);
    memcpy(d + 44, an_first ? snonce : anonce, 32);
    prf_sha1(pmk, 32, "Pairwise key expansion", d, sizeof d, ptk, 48);
}

void wpa_eapol_mic(const u8 kck[16], const u8 *eapol, size_t len, u8 mic[16]) {
    u8 h[CC_SHA1_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA1, kck, 16, eapol, len, h);
    memcpy(mic, h, 16);
}

int wpa_aes_unwrap(const u8 kek[16], const u8 *in, size_t in_len, u8 *out) {
    if (in_len < 16 || in_len % 8) return -1;
    size_t out_len = in_len - 8;
    int r = CCSymmetricKeyUnwrap(kCCWRAPAES, CCrfc3394_iv, CCrfc3394_ivLen, kek, 16,
                                 in, in_len, out, &out_len);
    return r == kCCSuccess ? (int)out_len : -1;
}

struct ccmp_key { CCCryptorRef aes; };

ccmp_key *ccmp_key_new(const u8 tk[16]) {
    ccmp_key *k = calloc(1, sizeof *k);
    if (CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, tk, 16, NULL, &k->aes)
        != kCCSuccess) { free(k); return NULL; }
    return k;
}

void ccmp_key_free(ccmp_key *k) {
    if (!k) return;
    CCCryptorRelease(k->aes);
    free(k);
}

static inline void aes_block(ccmp_key *k, const u8 in[16], u8 out[16]) {
    size_t moved;
    CCCryptorUpdate(k->aes, in, 16, out, 16, &moved);
}

static size_t ccmp_aad_nonce(const u8 *hdr, size_t hdr_len, u64 pn, u8 nonce[13], u8 aad[32]) {
    u16 fc = hdr[0] | hdr[1] << 8;
    bool is_data = ((fc >> 2) & 3) == 2;
    bool qos = is_data && (fc & 0x0080);
    bool a4 = (fc & 0x0300) == 0x0300;
    u8 prio = 0;
    size_t qos_off = 24 + (a4 ? 6 : 0);
    if (qos) prio = hdr[qos_off] & 0x0f;

    nonce[0] = prio;
    memcpy(nonce + 1, hdr + 10, 6);
    for (int i = 0; i < 6; i++) nonce[7 + i] = (u8)(pn >> (8 * (5 - i)));

    size_t n = 0;
    u16 mfc = fc;
    if (is_data) mfc &= ~0x0070;
    mfc &= ~(0x0800 | 0x1000 | 0x2000);
    mfc |= 0x4000;
    if (qos) mfc &= ~0x8000;
    aad[n++] = mfc; aad[n++] = mfc >> 8;
    memcpy(aad + n, hdr + 4, 18); n += 18;
    aad[n++] = hdr[22] & 0x0f; aad[n++] = 0;
    if (a4) { memcpy(aad + n, hdr + 24, 6); n += 6; }
    if (qos) { aad[n++] = hdr[qos_off] & 0x0f; aad[n++] = 0; }
    (void)hdr_len;
    return n;
}

static void ccm_mic(ccmp_key *k, const u8 nonce[13], const u8 *aad, size_t aad_len,
                    const u8 *m, size_t len, u8 tag[16]) {
    u8 b[16], x[16];
    b[0] = 0x59;
    memcpy(b + 1, nonce, 13);
    b[14] = len >> 8; b[15] = len;
    aes_block(k, b, x);
    u8 ab[48] = {0};
    ab[0] = aad_len >> 8; ab[1] = aad_len;
    memcpy(ab + 2, aad, aad_len);
    size_t abl = (aad_len + 2 + 15) & ~15u;
    for (size_t i = 0; i < abl; i += 16) {
        for (int j = 0; j < 16; j++) x[j] ^= ab[i + j];
        aes_block(k, x, x);
    }
    for (size_t i = 0; i < len; i += 16) {
        size_t n = len - i < 16 ? len - i : 16;
        for (size_t j = 0; j < n; j++) x[j] ^= m[i + j];
        aes_block(k, x, x);
    }
    memcpy(tag, x, 16);
}

static void ccm_ctr(ccmp_key *k, const u8 nonce[13], const u8 *in, size_t len, u8 *out, u8 s0[16]) {
    u8 a[16], s[16];
    a[0] = 0x01;
    memcpy(a + 1, nonce, 13);
    a[14] = 0; a[15] = 0;
    aes_block(k, a, s0);
    for (size_t i = 0, ctr = 1; i < len; i += 16, ctr++) {
        a[14] = ctr >> 8; a[15] = ctr;
        aes_block(k, a, s);
        size_t n = len - i < 16 ? len - i : 16;
        for (size_t j = 0; j < n; j++) out[i + j] = in[i + j] ^ s[j];
    }
}

size_t ccmp_encrypt(ccmp_key *k, u64 pn, u8 keyid, const u8 *hdr, size_t hdr_len,
                    const u8 *plain, size_t len, u8 *out) {
    u8 nonce[13], aad[32], tag[16], s0[16];
    size_t aad_len = ccmp_aad_nonce(hdr, hdr_len, pn, nonce, aad);
    out[0] = pn; out[1] = pn >> 8; out[2] = 0; out[3] = 0x20 | (keyid << 6);
    out[4] = pn >> 16; out[5] = pn >> 24; out[6] = pn >> 32; out[7] = pn >> 40;
    ccm_mic(k, nonce, aad, aad_len, plain, len, tag);
    ccm_ctr(k, nonce, plain, len, out + CCMP_HDR_LEN, s0);
    for (int i = 0; i < CCMP_MIC_LEN; i++) out[CCMP_HDR_LEN + len + i] = tag[i] ^ s0[i];
    return CCMP_HDR_LEN + len + CCMP_MIC_LEN;
}

long ccmp_decrypt(ccmp_key *k, const u8 *hdr, size_t hdr_len, const u8 *in, size_t len,
                  u8 *out, u64 *pn_out) {
    if (len < CCMP_HDR_LEN + CCMP_MIC_LEN || !(in[3] & 0x20)) return -1;
    u64 pn = (u64)in[0] | (u64)in[1] << 8 | (u64)in[4] << 16 | (u64)in[5] << 24 |
             (u64)in[6] << 32 | (u64)in[7] << 40;
    size_t plen = len - CCMP_HDR_LEN - CCMP_MIC_LEN;
    u8 nonce[13], aad[32], tag[16], s0[16];
    size_t aad_len = ccmp_aad_nonce(hdr, hdr_len, pn, nonce, aad);
    ccm_ctr(k, nonce, in + CCMP_HDR_LEN, plen, out, s0);
    ccm_mic(k, nonce, aad, aad_len, out, plen, tag);
    u8 diff = 0;
    for (int i = 0; i < CCMP_MIC_LEN; i++) diff |= (tag[i] ^ s0[i]) ^ in[CCMP_HDR_LEN + plen + i];
    if (diff) return -1;
    if (pn_out) *pn_out = pn;
    return (long)plen;
}

static int check(const char *what, const u8 *got, const u8 *want, size_t n) {
    if (!memcmp(got, want, n)) return 0;
    fprintf(stderr, "selftest %s FAILED\n  got : ", what);
    for (size_t i = 0; i < n; i++) fprintf(stderr, "%02x", got[i]);
    fprintf(stderr, "\n  want: ");
    for (size_t i = 0; i < n; i++) fprintf(stderr, "%02x", want[i]);
    fprintf(stderr, "\n");
    return 1;
}

int wifi_crypto_selftest(void) {
    int fails = 0;
    static const u8 pmk_want[32] = {
        0xf4,0x2c,0x6f,0xc5,0x2d,0xf0,0xeb,0xef,0x9e,0xbb,0x4b,0x90,0xb3,0x8a,0x5f,0x90,
        0x2e,0x83,0xfe,0x1b,0x13,0x5a,0x70,0xe2,0x3a,0xed,0x76,0x2e,0x97,0x10,0xa1,0x2e};
    u8 pmk[32];
    wpa_pmk("password", (const u8 *)"IEEE", 4, pmk);
    fails += check("PBKDF2 PMK", pmk, pmk_want, 32);

    static const u8 tk[16] = {0xc9,0x7c,0x1f,0x67,0xce,0x37,0x11,0x85,0x51,0x4a,0x8a,0x19,0xf2,0xbd,0xd5,0x2f};
    static const u8 hdr[24] = {0x08,0x48,0xc3,0x2c,0x0f,0xd2,0xe1,0x28,0xa5,0x7c,0x50,0x30,
                               0xf1,0x84,0x44,0x08,0xab,0xae,0xa5,0xb8,0xfc,0xba,0x80,0x33};
    static const u8 pt[20] = {0xf8,0xba,0x1a,0x55,0xd0,0x2f,0x85,0xae,0x96,0x7b,0xb6,0x2f,
                              0xb6,0xcd,0xa8,0xeb,0x7e,0x78,0xa0,0x50};
    static const u8 ct_want[36] = {
        0x0c,0xe7,0x00,0x20,0x76,0x97,0x03,0xb5,
        0xf3,0xd0,0xa2,0xfe,0x9a,0x3d,0xbf,0x23,0x42,0xa6,0x43,0xe4,0x32,0x46,0xe8,0x0c,
        0x3c,0x04,0xd0,0x19,
        0x78,0x45,0xce,0x0b,0x16,0xf9,0x76,0x23};
    ccmp_key *k = ccmp_key_new(tk);
    u8 out[64], back[64];
    size_t n = ccmp_encrypt(k, 0xB5039776E70CULL, 0, hdr, 24, pt, 20, out);
    fails += check("CCMP encrypt", out, ct_want, 36);
    u64 pn = 0;
    long m = ccmp_decrypt(k, hdr, 24, out, n, back, &pn);
    if (m != 20 || pn != 0xB5039776E70CULL) { fprintf(stderr, "selftest CCMP decrypt FAILED\n"); fails++; }
    else fails += check("CCMP decrypt", back, pt, 20);
    out[20] ^= 1;
    if (ccmp_decrypt(k, hdr, 24, out, n, back, NULL) >= 0) { fprintf(stderr, "selftest CCMP tamper FAILED\n"); fails++; }
    ccmp_key_free(k);
    return fails;
}
