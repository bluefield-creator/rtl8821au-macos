#pragma once
#include "compat.h"
#include <stddef.h>

typedef struct {
    const u8 *frame;
    size_t len;
    u8 rate;
    s8 rssi;
    bool crc_err, icv_err, decrypted, is_c2h;
    u8 macid;
} rtl_rx_pkt;

typedef void (*rtl_rx_cb)(const rtl_rx_pkt *pkt, void *ctx);

int rtl_rx_parse(const u8 *buf, size_t len, rtl_rx_cb cb, void *ctx);
