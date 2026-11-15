#pragma once
#include "compat.h"
#include <stddef.h>

#define CCMP_HDR_LEN 8
#define CCMP_MIC_LEN 8

void wpa_pmk(const char *passphrase, const u8 *ssid, size_t ssid_len, u8 pmk[32]);
void wpa_ptk(const u8 pmk[32], const u8 aa[6], const u8 spa[6],
             const u8 anonce[32], const u8 snonce[32], u8 ptk[48]);
void wpa_eapol_mic(const u8 kck[16], const u8 *eapol, size_t len, u8 mic[16]);
int  wpa_aes_unwrap(const u8 kek[16], const u8 *in, size_t in_len, u8 *out);

typedef struct ccmp_key ccmp_key;
ccmp_key *ccmp_key_new(const u8 tk[16]);
void ccmp_key_free(ccmp_key *k);

size_t ccmp_encrypt(ccmp_key *k, u64 pn, u8 keyid, const u8 *hdr, size_t hdr_len,
                    const u8 *plain, size_t len, u8 *out);
long ccmp_decrypt(ccmp_key *k, const u8 *hdr, size_t hdr_len, const u8 *in, size_t len,
                  u8 *out, u64 *pn_out);

int wifi_crypto_selftest(void);
