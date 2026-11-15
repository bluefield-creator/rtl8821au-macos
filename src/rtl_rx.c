// Descriptor layout from Linux rtw88 rx.h / rtw88xxa.c (BSD-3-Clause).
#include "rtl_rx.h"
#include <string.h>

#define RX_DESC_SZ 24
#define FCS_LEN    4

static inline u32 le32(const u8 *p) { return p[0] | p[1] << 8 | p[2] << 16 | (u32)p[3] << 24; }

static s8 cck_rx_pwr(u8 lna, u8 vga) {
    static const s8 lna_gain[] = {15, -1, -17, 0, -30, -38};
    switch (lna) {
    case 0: case 1: case 2: case 4: case 5: return lna_gain[lna] - 2 * vga;
    default: return -100;
    }
}

int rtl_rx_parse(const u8 *buf, size_t len, rtl_rx_cb cb, void *ctx) {
    int n = 0;
    size_t off = 0;
    while (off + RX_DESC_SZ <= len) {
        const u8 *d = buf + off;
        u32 w0 = le32(d), w1 = le32(d + 4), w2 = le32(d + 8), w3 = le32(d + 12);
        u32 pkt_len = w0 & 0x3fff;
        u32 drv_info = ((w0 >> 16) & 0xf) * 8;
        u32 shift = (w0 >> 24) & 0x3;
        bool physt = w0 & BIT(26);
        u32 total = RX_DESC_SZ + drv_info + shift + pkt_len;
        if (pkt_len == 0 || off + total > len) break;

        rtl_rx_pkt p = {0};
        p.crc_err = w0 & BIT(14);
        p.icv_err = w0 & BIT(15);
        u32 enc = (w0 >> 20) & 7;
        p.decrypted = !(w0 & BIT(27)) && enc != 0;
        p.macid = w1 & 0x7f;
        p.is_c2h = w2 & BIT(28);
        p.rate = w3 & 0x7f;
        const u8 *phy = d + RX_DESC_SZ + shift;
        p.frame = phy + drv_info;
        p.len = pkt_len;
        if (!p.is_c2h && p.len > FCS_LEN) p.len -= FCS_LEN;
        p.rssi = -100;
        if (physt && drv_info >= 8) {
            u32 pw0 = le32(phy), pw1 = le32(phy + 4);
            if (p.rate <= 3) p.rssi = cck_rx_pwr((pw1 >> 13) & 7, (pw1 >> 8) & 0x1f);
            else p.rssi = (s8)((int)(pw0 & 0x7f) - 110);
        }
        cb(&p, ctx);
        n++;
        off += (total + 7) & ~7u;
    }
    return n;
}
