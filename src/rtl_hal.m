// Ported from Linux rtw88 (rtw88xxa.c / rtw8821a.c / mac.c / phy.c),
// Copyright(c) 2018-2024 Realtek Corporation, used under BSD-3-Clause.
#import "rtl_hal.h"
#include "rtw_tables.h"
#include "vendor/rtw_reg.h"
#include "vendor/rtw88xxa_regs.h"
#include <unistd.h>

#define RTW_SEC_CMD_REG   0x670
#define REG_MACID         0x0610
#define REG_BSSID         0x0618
#define BIT_ADF           BIT(11)
#define RTW_SEC_CONFIG    0x680
#define PHY_STATUS_SIZE   4
#define REPORT_BUF        128
#define RXFF_SIZE         16128
#define TXFF_SIZE         65536
#define PAGE_SIZE_TX      256
#define RSVD_DRV_PG_NUM   8
#define USB_TX_AGG_DESC   6

#define LOG(...) do { if (self.verbose) { fprintf(stderr, "hal: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

static void udelay(unsigned us) { usleep(us); }
static void mdelay(unsigned ms) { usleep(ms * 1000); }

@implementation RTLHal {
    rtw_efuse_t _ef;
    u32 _phyCond, _phyCond2;
    u16 _rsvdBoundary;
    u8 _iqkBand, _iqkBw;
}

- (instancetype)initWithUSB:(RTLUSB *)usb {
    if ((self = [super init])) { _usb = usb; }
    return self;
}
- (rtw_efuse_t *)efuse { return &_ef; }

- (u8)rd8:(u16)a   { return [_usb rd8:a]; }
- (u16)rd16:(u16)a { return [_usb rd16:a]; }
- (u32)rd32:(u16)a { return [_usb rd32:a]; }
- (void)wr8:(u16)a v:(u8)v   { [_usb wr8:a val:v]; }
- (void)wr16:(u16)a v:(u16)v { [_usb wr16:a val:v]; }
- (void)wr32:(u16)a v:(u32)v { [_usb wr32:a val:v]; }
- (void)set8:(u16)a b:(u8)b   { [self wr8:a v:[self rd8:a] | b]; }
- (void)clr8:(u16)a b:(u8)b   { [self wr8:a v:[self rd8:a] & ~b]; }
- (void)set16:(u16)a b:(u16)b { [self wr16:a v:[self rd16:a] | b]; }
- (void)clr16:(u16)a b:(u16)b { [self wr16:a v:[self rd16:a] & ~b]; }
- (void)set32:(u16)a b:(u32)b { [self wr32:a v:[self rd32:a] | b]; }
- (void)clr32:(u16)a b:(u32)b { [self wr32:a v:[self rd32:a] & ~b]; }
- (u32)rd32:(u16)a mask:(u32)m { return field_get(m, [self rd32:a]); }
- (void)wr32:(u16)a mask:(u32)m v:(u32)v {
    if (m == MASKDWORD) { [self wr32:a v:v]; return; }
    u32 old = [self rd32:a];
    [self wr32:a v:(old & ~m) | field_prep(m, v)];
}
- (BOOL)poll8:(u16)a mask:(u8)m target:(u8)t timeoutUs:(unsigned)to {
    for (unsigned el = 0; el <= to; el += 50) {
        if (([self rd8:a] & m) == (t & m)) return YES;
        udelay(50);
    }
    return NO;
}

- (u32)readRF:(u32)addr mask:(u32)mask {
    addr &= 0xff;
    bool pi = [self rd32:REG_3WIRE_SWA mask:0x4];
    [self wr32:REG_HSSI_READ mask:MASKBYTE0 v:addr];
    udelay(20);
    return [self rd32:(pi ? REG_PI_READ_A : REG_SI_READ_A) mask:mask];
}

- (void)writeRF:(u32)addr mask:(u32)mask v:(u32)data {
    addr &= 0xff;
    mask &= RFREG_MASK;
    if (mask != RFREG_MASK) {
        u32 old = [self readRF:addr mask:RFREG_MASK];
        data = (old & ~mask) | ((data << rtw_ffs(mask)) & mask);
    }
    [self wr32:REG_LSSI_WRITE_A v:((addr << 20) | (data & 0xfffff)) & 0x0fffffff];
    udelay(13);
}

- (int)efuseByte:(u16)addr {
    [self wr8:REG_EFUSE_CTRL + 1 v:addr & 0xff];
    [self wr8:REG_EFUSE_CTRL + 2 v:([self rd8:REG_EFUSE_CTRL + 2] & 0xfc) | ((addr >> 8) & 3)];
    [self wr8:REG_EFUSE_CTRL + 3 v:[self rd8:REG_EFUSE_CTRL + 3] & 0x7f];
    for (int i = 0; i < 1000; i++)
        if ([self rd32:REG_EFUSE_CTRL] & BIT(31)) return [self rd8:REG_EFUSE_CTRL];
    return -1;
}

- (BOOL)readEfuse {
    u32 cfg = [self rd32:REG_SYS_CFG1];
    _cut = (cfg >> 12) & 0xf;
    _btcoex = [self rd32:REG_WL_BT_PWR_CTRL mask:BIT_BT_FUNC_EN];

    [self wr8:REG_EFUSE_ACCESS v:EFUSE_ACCESS_ON];
    [self set16:REG_SYS_FUNC_EN b:BIT_FEN_ELDR];
    [self set16:REG_SYS_CLKR b:BIT_LOADER_CLK_EN | BIT_ANA8M];

    memset(_ef.map, 0xff, sizeof _ef.map);
    int p = 0;
    BOOL ok = YES;
    while (p < 512) {
        int hdr = [self efuseByte:p++];
        if (hdr < 0) { ok = NO; break; }
        if (hdr == 0xff) break;
        int off, wen;
        if ((hdr & 0x1f) == 0x0f) {
            int h2 = [self efuseByte:p++];
            if (h2 < 0) { ok = NO; break; }
            if ((h2 & 0x0f) == 0x0f) continue;
            off = ((h2 & 0xf0) >> 1) | ((hdr >> 5) & 7);
            wen = h2 & 0x0f;
        } else {
            off = (hdr >> 4) & 0x0f;
            wen = hdr & 0x0f;
        }
        for (int w = 0; w < 4; w++) {
            if (wen & (1 << w)) continue;
            int lo = [self efuseByte:p++], hi = [self efuseByte:p++];
            int la = off * 8 + w * 2;
            if (la + 1 < 512) { _ef.map[la] = lo; _ef.map[la + 1] = hi; }
        }
    }
    [self wr8:REG_EFUSE_ACCESS v:EFUSE_ACCESS_OFF];
    if (!ok) return NO;

    const u8 *m = _ef.map;
    if (m[0] != 0x29 || m[1] != 0x81) {
        fprintf(stderr, "hal: eFuse has bad signature %02x%02x\n", m[1], m[0]);
        return NO;
    }
    memcpy(_ef.mac, m + 0x107, 6);
    _ef.crystal_cap  = m[0xb9] == 0xff ? 0x20 : m[0xb9];
    _ef.thermal      = m[0xba];
    _ef.pa_type      = m[0xbc];
    _ef.lna_type_2g  = m[0xbd];
    _ef.lna_type_5g  = m[0xbf];
    _ef.board_option = m[0xc1];
    _ef.bt_setting   = m[0xc3];
    _ef.swing_2g     = m[0xc6];
    _ef.swing_5g     = m[0xc7];
    _ef.rfe_option   = m[0xca];

    u32 cut = _cut ? _cut : 15;
    u32 rfe = (_ef.ext_lna_2g) | (_ef.ext_pa_2g << 1) | (_ef.ext_lna_5g << 2) |
              (_ef.ext_pa_5g << 3) | ((_btcoex ? 1 : 0) << 4);
    _phyCond = rfe | (2u << 8) | (15u << 12) | (4u << 16) | (cut << 24);
    _phyCond2 = _ef.glna_type | (_ef.gpa_type << 8) | (_ef.alna_type << 16) | (_ef.apa_type << 24);
    LOG("cut=%c btcoex=%d xtal=0x%02x thermal=0x%02x phycond=0x%08x",
        'A' + _cut, _btcoex, _ef.crystal_cap, _ef.thermal, _phyCond);
    return YES;
}

- (BOOL)runPwrSeq:(const struct rtw_pwr_seq_cmd *const *)seq {
    u8 cutMask = BIT(_cut + 1);
    for (int i = 0; seq[i]; i++) {
        for (const struct rtw_pwr_seq_cmd *c = seq[i]; c->cmd != RTW_PWR_CMD_END; c++) {
            if (!(c->intf_mask & RTW_PWR_INTF_USB_MSK) || !(c->cut_mask & cutMask)) continue;
            switch (c->cmd) {
            case RTW_PWR_CMD_WRITE: {
                u8 v = [self rd8:c->offset];
                v = (v & ~c->mask) | (c->value & c->mask);
                [self wr8:c->offset v:v];
                break;
            }
            case RTW_PWR_CMD_POLLING:
                if (![self poll8:c->offset mask:c->mask target:c->value timeoutUs:50 * 2000]) {
                    fprintf(stderr, "hal: pwr poll timeout 0x%04x mask 0x%02x val 0x%02x\n",
                            c->offset, c->mask, c->value);
                    return NO;
                }
                break;
            case RTW_PWR_CMD_DELAY:
                if (c->value == RTW_PWR_DELAY_US) udelay(c->offset); else mdelay(c->offset);
                break;
            default: break;
            }
        }
    }
    return YES;
}

typedef enum { CFG_MAC, CFG_BB, CFG_AGC, CFG_RF } cfg_kind;

- (BOOL)condPositive:(u32)cond cond2:(u32)cond2 {
    u32 ccut = (cond >> 24) & 0xf, cpkg = (cond >> 12) & 0xf, cintf = (cond >> 8) & 0xf;
    u32 crfe = cond & 0xff;
    u32 dcut = (_phyCond >> 24) & 0xf, dpkg = (_phyCond >> 12) & 0xf, dintf = (_phyCond >> 8) & 0xf;
    u32 drfe = _phyCond & 0xff;
    if (ccut && ccut != dcut) return NO;
    if (cpkg && cpkg != dpkg) return NO;
    if (cintf && cintf != dintf) return NO;
    if (!(crfe & 0x0f)) return YES;
    if ((crfe & drfe) != crfe) return NO;
    if ((crfe & BIT(0)) && (cond2 & 0xff) != (_phyCond2 & 0xff)) return NO;
    if ((crfe & BIT(1)) && ((cond2 >> 8) & 0xff) != ((_phyCond2 >> 8) & 0xff)) return NO;
    if ((crfe & BIT(2)) && ((cond2 >> 16) & 0xff) != ((_phyCond2 >> 16) & 0xff)) return NO;
    if ((crfe & BIT(3)) && ((cond2 >> 24) & 0xff) != ((_phyCond2 >> 24) & 0xff)) return NO;
    return YES;
}

- (void)loadTable:(const u32 *)t size:(unsigned)n kind:(cfg_kind)kind {
    u32 posCond = 0, posCond2 = 0;
    bool matched = true, skipped = false;
    unsigned writes = 0;
    for (unsigned i = 0; i + 1 < n; i += 2) {
        u32 a = t[i], d = t[i + 1];
        bool pos = a & BIT(31), neg = a & BIT(30);
        if (pos) {
            u32 branch = (a >> 28) & 3;
            if (branch == 3) { matched = true; skipped = false; }
            else if (branch == 2) { matched = !skipped; }
            else { posCond = a; posCond2 = d; }
        } else if (neg) {
            if (!skipped) {
                if ([self condPositive:posCond cond2:posCond2]) { matched = true; skipped = true; }
                else { matched = false; skipped = false; }
            } else matched = false;
        } else if (matched) {
            writes++;
            switch (kind) {
            case CFG_MAC: [self wr8:a v:d]; break;
            case CFG_AGC: [self wr32:a v:d]; break;
            case CFG_BB:
                if (a == 0xfe) mdelay(50); else if (a == 0xfd) mdelay(5);
                else if (a == 0xfc) mdelay(1); else if (a == 0xfb) udelay(50);
                else if (a == 0xfa) udelay(5); else if (a == 0xf9) udelay(1);
                else [self wr32:a v:d];
                break;
            case CFG_RF:
                if (a == 0xffe) mdelay(50); else if (a == 0xfe) udelay(100);
                else { [self writeRF:a mask:RFREG_MASK v:d]; udelay(1); }
                break;
            }
        }
    }
    LOG("table kind %d: %u writes", kind, writes);
}

- (void)wlanCpu:(BOOL)en {
    if (en) {
        [self set8:REG_RSV_CTRL + 1 b:BIT_WLMCU_IOIF];
        [self set8:REG_SYS_FUNC_EN + 1 b:BIT_FEN_CPUEN];
    } else {
        [self clr8:REG_SYS_FUNC_EN + 1 b:BIT_FEN_CPUEN];
        [self clr8:REG_RSV_CTRL + 1 b:BIT_WLMCU_IOIF];
    }
}

- (void)reset8051 {
    [self clr8:REG_RSV_CTRL b:BIT(1)];
    [self clr8:REG_RSV_CTRL + 1 b:BIT(0)];
    u8 v = [self rd8:REG_SYS_FUNC_EN + 1];
    [self wr8:REG_SYS_FUNC_EN + 1 v:v & ~BIT(2)];
    [self clr8:REG_RSV_CTRL b:BIT(1)];
    [self set8:REG_RSV_CTRL + 1 b:BIT(0)];
    [self wr8:REG_SYS_FUNC_EN + 1 v:v | BIT(2)];
}

- (BOOL)downloadFirmware:(NSData *)fw {
    const u8 *p = fw.bytes;
    if (fw.length < 64) return NO;
    u16 sig = p[0] | p[1] << 8;
    if ((sig & 0xfff0) != 0x2100) {
        fprintf(stderr, "hal: firmware signature 0x%04x is not RTL8821A\n", sig);
        return NO;
    }
    LOG("firmware v%u.%u (%02u-%02u %02u:%02u)", p[4] | p[5] << 8, p[6], p[8], p[9], p[10], p[11]);
    p += 32;
    u32 size = (u32)fw.length - 32;

    [self wlanCpu:NO];
    [self wlanCpu:YES];
    [self set8:REG_MCUFW_CTRL b:BIT_MCUFWDL_EN];
    for (int t = 0; t < 10 && !([self rd8:REG_MCUFW_CTRL] & BIT_MCUFWDL_EN); t++) {
        [self set8:REG_MCUFW_CTRL b:BIT_MCUFWDL_EN];
        mdelay(20);
    }
    [self clr32:REG_MCUFW_CTRL b:BIT_ROM_DLEN];

    [self set8:REG_MCUFW_CTRL b:BIT_FWDL_CHK_RPT];
    u32 pages = (size + 0xfff) >> 12;
    for (u32 pg = 0; pg < pages; pg++) {
        u32 len = MIN(0x1000u, size - pg * 0x1000);
        const u8 *d = p + pg * 0x1000;
        [self wr32:REG_MCUFW_CTRL mask:BIT_ROM_PGE v:pg];
        u32 addr = 0x1000, off = 0;
        while (off < len) {
            u32 n = (len - off >= 196) ? 196 : (len - off >= 8 ? 8 : 1);
            if (![_usb writeBlock:addr data:d + off len:n]) return NO;
            addr += n; off += n;
        }
    }
    BOOL rpt = NO;
    for (int i = 0; i < 1000 && !rpt; i++) {
        rpt = ([self rd8:REG_MCUFW_CTRL] & BIT_FWDL_CHK_RPT) != 0;
        if (!rpt) udelay(10);
    }
    [self clr8:REG_MCUFW_CTRL b:BIT_MCUFWDL_EN];
    if (!rpt) { fprintf(stderr, "hal: firmware checksum report not set\n"); return NO; }

    u32 v = [self rd32:REG_MCUFW_CTRL];
    v |= BIT_MCUFWDL_RDY;
    v &= ~BIT_WINTINI_RDY;
    [self wr32:REG_MCUFW_CTRL v:v];
    [self wlanCpu:NO];
    [self wlanCpu:YES];
    for (int t = 0; t < 50; t++) {
        v = [self rd32:REG_MCUFW_CTRL];
        if ((v & FW_READY_LEGACY) == FW_READY_LEGACY) { LOG("firmware running (MCUFW_CTRL=0x%08x)", v); return YES; }
        mdelay(20);
    }
    fprintf(stderr, "hal: firmware did not report ready (MCUFW_CTRL=0x%08x)\n", v);
    return NO;
}

- (void)hwReset {
    if (!([self rd8:REG_MCUFW_CTRL] & BIT_RAM_DL_SEL)) return;
    LOG("chip was left initialised; resetting");
    [self reset8051];
    [self wr8:REG_MCUFW_CTRL v:0];
    [self set32:REG_FPGA0_XCD_RF_PARA b:BIT(6)];
    [self clr8:REG_SYS_FUNC_EN b:BIT(0) | BIT(1)];
    [self wr8:REG_RF_CTRL v:0];
    [self wr16:REG_CR v:0];
    [self set8:REG_APS_FSMCO + 1 b:APS_FSMCO_MAC_OFF >> 8];
    u8 v = 0;
    for (int i = 0; i < 5000; i++) { v = [self rd8:REG_APS_FSMCO + 1]; if (!(v & (APS_FSMCO_MAC_OFF >> 8))) break; udelay(1); }
    [self wr8:REG_APS_FSMCO + 1 v:v | (APS_FSMCO_MAC_ENABLE >> 8)];
    [self clr8:REG_SYS_FUNC_EN + 1 b:BIT(4) | BIT(7)];
    [self set8:REG_SYS_FUNC_EN + 1 b:BIT(4) | BIT(7)];
}

- (BOOL)lltWrite:(u32)addr data:(u32)data {
    [self wr32:REG_LLT_INIT v:BIT_LLT_WRITE_ACCESS | (addr << 8) | data];
    for (int c = 0; c < 20; c++)
        if (![self rd32:REG_LLT_INIT mask:BIT(31) | BIT(30)]) return YES;
    fprintf(stderr, "hal: LLT write %u timed out\n", addr);
    return NO;
}

- (BOOL)lltInit:(u32)boundary {
    for (u32 i = 0; i < boundary - 1; i++) if (![self lltWrite:i data:i + 1]) return NO;
    if (![self lltWrite:boundary - 1 data:0xff]) return NO;
    for (u32 i = boundary; i < 255; i++) if (![self lltWrite:i data:i + 1]) return NO;
    return [self lltWrite:255 data:boundary];
}

- (BOOL)powerOnWithFirmware:(NSData *)fw {
    [self hwReset];
    if (![self runPwrSeq:card_enable_flow_8821a]) { fprintf(stderr, "hal: power on flow failed\n"); return NO; }
    [self wr16:REG_CR v:0];
    [self set16:REG_CR b:BIT_HCI_TXDMA_EN | BIT_HCI_RXDMA_EN | BIT_TXDMA_EN | BIT_RXDMA_EN |
                         BIT_PROTOCOL_EN | BIT_SCHEDULE_EN | BIT_MAC_SEC_EN | BIT_32K_CAL_TMR_EN];
    if ([self rd8:REG_SYS_CFG1 + 3] & BIT(0)) [self set8:REG_LDO_SWR_CTRL b:BIT(6)];
    LOG("MAC powered on, REG_CR=0x%04x", [self rd16:REG_CR]);

    u16 txffPg = TXFF_SIZE / PAGE_SIZE_TX;
    _rsvdBoundary = txffPg - RSVD_DRV_PG_NUM;
    u16 acqPg = _rsvdBoundary;
    if (![self lltInit:_rsvdBoundary]) return NO;
    [self set32:REG_TXDMA_OFFSET_CHK b:BIT_DROP_DATA_EN];

    if (![self downloadFirmware:fw]) return NO;
    [self wr8:REG_HMETFR v:0xf];

    [self loadTable:rtw8821a_mac size:rtw8821a_mac_size kind:CFG_MAC];

    int nOut = _usb.bulkOutCount;
    u8 hq = 8, lq = 0, nq = 0, exq = 0, gap = 1;
    if (nOut == 3) { lq = 8; } else if (nOut >= 4) { lq = 8; exq = 4; }
    u16 pubq = acqPg - hq - lq - nq - exq - gap;
    [self wr32:REG_RQPN_NPQ v:BIT_RQPN_NE(nq, exq)];
    [self wr32:REG_RQPN v:BIT_RQPN_HLP(hq, lq, pubq)];
    LOG("bulk-out=%d pubq=%u boundary=%u", nOut, pubq, _rsvdBoundary);

    [self wr8:REG_BCNQ_BDNY v:_rsvdBoundary];
    [self wr8:REG_MGQ_BDNY v:_rsvdBoundary];
    [self wr8:REG_WMAC_LBK_BF_HD v:_rsvdBoundary];
    [self wr8:REG_TRXFF_BNDY v:_rsvdBoundary];
    [self wr8:REG_DWBCN0_CTRL + 1 v:_rsvdBoundary];

    enum { MAP_EXTRA = 0, MAP_LOW = 1, MAP_NORMAL = 2, MAP_HIGH = 3 };
    u8 vo, vi, be, bk, mg, hi;
    if (nOut == 2) { vo = MAP_HIGH; vi = MAP_HIGH; be = MAP_NORMAL; bk = MAP_NORMAL; mg = MAP_HIGH; hi = MAP_HIGH; }
    else if (nOut == 3) { vo = MAP_HIGH; vi = MAP_NORMAL; be = MAP_LOW; bk = MAP_LOW; mg = MAP_HIGH; hi = MAP_HIGH; }
    else { vo = MAP_NORMAL; vi = MAP_NORMAL; be = MAP_LOW; bk = MAP_LOW; mg = MAP_EXTRA; hi = MAP_HIGH; }
    u16 pq = [self rd16:REG_TXDMA_PQ_MAP] & 0x7;
    pq |= BIT_TXDMA_HIQ_MAP(hi) | BIT_TXDMA_MGQ_MAP(mg) | BIT_TXDMA_BKQ_MAP(bk) |
          BIT_TXDMA_BEQ_MAP(be) | BIT_TXDMA_VIQ_MAP(vi) | BIT_TXDMA_VOQ_MAP(vo);
    [self wr16:REG_TXDMA_PQ_MAP v:pq];
    if (nOut == 4) [self wr8:REG_HIQ_NO_LMT_EN v:0xff];

    [self wr16:REG_TRXFF_BNDY + 2 v:RXFF_SIZE - REPORT_BUF - 1];
    [self wr8:REG_RX_DRVINFO_SZ v:PHY_STATUS_SIZE];
    [self wr32:REG_HIMR0 v:0];
    [self wr32:REG_HIMR1 v:0];
    [self wr32:REG_CR mask:0x30000 v:0x2];

    [self wr16:REG_RXFLTMAP0 v:0xffff];
    [self wr16:REG_RXFLTMAP1 v:0x0400];
    [self wr16:REG_RXFLTMAP2 v:0xffff];
    [self wr32:REG_MAR v:0xffffffff];
    [self wr32:REG_MAR + 4 v:0xffffffff];
    [self wr32:REG_RRSR mask:0xfffff v:0xffff1];
    [self wr16:REG_RETRY_LIMIT v:0x3030];
    [self wr16:REG_SPEC_SIFS v:0x100a];
    [self wr16:REG_MAC_SPEC_SIFS v:0x100a];
    [self wr16:REG_SIFS v:0x100a];
    [self wr16:REG_SIFS + 2 v:0x100a];
    [self wr32:REG_EDCA_BE_PARAM v:0x005EA42B];
    [self wr32:REG_EDCA_BK_PARAM v:0x0000A44F];
    [self wr32:REG_EDCA_VI_PARAM v:0x005EA324];
    [self wr32:REG_EDCA_VO_PARAM v:0x002FA226];
    [self wr8:REG_USTIME_TSF v:0x50];
    [self wr8:REG_USTIME_EDCA v:0x50];

    [self set8:REG_FWHW_TXQ_CTRL b:BIT(7)];
    [self wr8:REG_ACKTO v:0x80];
    [self wr32:REG_DWBCN0_CTRL mask:0xf0 v:USB_TX_AGG_DESC];
    [self wr8:REG_DWBCN1_CTRL v:USB_TX_AGG_DESC << 1];
    u16 bc = (BIT_DIS_TSF_UDT << 8) | BIT_DIS_TSF_UDT;
    if (_btcoex) bc |= BIT_EN_BCN_FUNCTION;
    [self wr16:REG_BCN_CTRL v:bc];
    [self wr32:REG_TBTT_PROHIBIT mask:0xfffff v:WLAN_TBTT_TIME];
    [self wr8:REG_DRVERLYINT v:0x05];
    [self wr8:REG_BCNDMATIM v:WLAN_BCN_DMA_TIME];
    [self wr16:REG_BCNTCFG v:0x4413];
    [self wr8:REG_BCN_MAX_ERR v:0xff];

    u8 rxdma = BIT_DMA_BURST_CNT | BIT_DMA_MODE;
    rxdma = (rxdma & ~BIT_DMA_BURST_SIZE) | field_prep(BIT_DMA_BURST_SIZE,
              _usb.highSpeed ? BIT_DMA_BURST_SIZE_512 : BIT_DMA_BURST_SIZE_64);
    [self wr8:REG_RXDMA_MODE v:rxdma];
    [self set16:REG_TXDMA_OFFSET_CHK b:BIT_DROP_DATA_EN];

    [self wr8:REG_USB3_RXITV v:0x01];
    [self wr16:REG_RXDMA_STATUS v:0x7400];
    [self wr8:REG_RXDMA_STATUS + 1 v:0xf5];
    [self wr8:REG_AMPDU_MAX_TIME v:0x5e];
    [self wr32:REG_AMPDU_MAX_LENGTH v:0xffffffff];
    [self wr8:REG_USTIME_TSF v:0x50];
    [self wr8:REG_USTIME_EDCA v:0x50];
    [self set8:REG_SINGLE_AMPDU_CTRL b:BIT_EN_SINGLE_APMDU];
    [self wr8:REG_RX_PKT_LIMIT v:0x18];
    [self wr8:REG_PIFS v:0x00];
    [self wr16:REG_MAX_AGGR_NUM v:0x1f1f];
    [self wr8:REG_FWHW_TXQ_CTRL v:0x80];
    [self wr32:REG_FAST_EDCA_CTRL v:0x03087777];
    [self set8:REG_RSV_CTRL b:BIT(5) | BIT(6)];
    [self wr32:REG_ARFR0 v:0x00000010];
    [self wr32:REG_ARFRH0 v:0xfffff000];
    [self wr32:REG_ARFR1_V1 v:0x00000010];
    [self wr32:REG_ARFRH1_V1 v:0x003ff000];
    [self wr32:REG_ARFR2_V1 v:0x00000015];
    [self wr32:REG_ARFRH2_V1 v:0x003ff000];
    [self wr32:REG_ARFR3_V1 v:0x00000015];
    [self wr32:REG_ARFRH3_V1 v:0xffcff000];
    [self set8:REG_CR b:BIT_MACTXEN | BIT_MACRXEN];

    u8 v8 = [self rd8:REG_SYS_FUNC_EN] | BIT_FEN_USBA;
    [self wr8:REG_SYS_FUNC_EN v:v8];
    v8 |= BIT_FEN_BB_RSTB | BIT_FEN_BB_GLB_RST;
    [self wr8:REG_SYS_FUNC_EN v:v8];
    [self wr8:REG_RF_CTRL v:BIT_RF_EN | BIT_RF_RSTB | BIT_RF_SDM_RSTB];
    [self wr8:REG_RF_B_CTRL v:BIT_RF_EN | BIT_RF_RSTB | BIT_RF_SDM_RSTB];
    [self loadTable:rtw8821a_bb size:rtw8821a_bb_size kind:CFG_BB];
    [self loadTable:rtw8821a_agc size:rtw8821a_agc_size kind:CFG_AGC];
    u8 xc = _ef.crystal_cap & 0x3f;
    [self wr32:REG_AFE_CTRL3 mask:0x00FFF000 v:xc | (xc << 6)];
    [self loadTable:rtw8821a_rf_a size:rtw8821a_rf_a_size kind:CFG_RF];

    _band = 0xff; _iqkBand = 0xff; _iqkBw = 0xff;
    [self switchBand:BAND_2G bw:BW_20];

    [self wr32:RTW_SEC_CMD_REG v:BIT(31) | BIT(30)];
    [self wr8:REG_HWSEQ_CTRL v:0xff];
    [self wr32:REG_BAR_MODE_CTRL v:0x0201ffff];
    [self wr8:REG_NAV_CTRL + 2 v:0];
    [self clr8:REG_GPIO_MUXCFG b:BIT(5)];
    [self clr8:REG_QUEUE_CTRL b:BIT(3)];
    [self wr8:REG_FWHW_TXQ_CTRL + 1 v:0x0f];
    [self wr8:REG_EARLY_MODE_CONTROL + 3 v:0x01];
    [self wr16:REG_TX_RPT_TIME v:0x3df0];
    [self wr8:REG_SYS_SDIO_CTRL v:0x0];
    [self wr8:REG_ACLK_MON v:0x0];
    [self wr8:REG_USB_HRPWM v:0];
    [self set32:REG_FWHW_TXQ_CTRL b:BIT(12)];

    u16 agg = field_prep(BIT_RXDMA_AGG_PG_TH, 0x5) | field_prep(BIT_DMA_AGG_TO_V1, 0x20);
    [self wr16:REG_RXDMA_AGG_PG_TH v:agg];
    [self set8:REG_TXDMA_PQ_MAP b:BIT_RXDMA_AGG_EN];

    [self setMacAddress:_ef.mac];
    LOG("power on complete");
    return YES;
}

- (void)powerOff {
    u8 cr = [self rd8:REG_CR];
    if (cr == 0 || cr == 0xEA) return;
    if (!_btcoex) [self clr16:REG_GPIO_MUXCFG b:BIT_EN_SIC];
    [self wr32:REG_HISR0 v:0xffffffff];
    [self wr32:REG_HISR1 v:0xffffffff];
    [self wr32:REG_HIMR0 v:0];
    [self wr32:REG_HIMR1 v:0];
    u16 fsm = [self rd16:REG_APS_FSMCO];
    [self wr16:REG_APS_FSMCO v:fsm & ~APS_FSMCO_HW_POWERDOWN];
    [self clr8:REG_TX_RPT_CTRL b:BIT(1)];
    [self wr8:REG_CR v:0];
    [self runPwrSeq:enter_lps_flow_8821a];
    if ([self rd8:REG_MCUFW_CTRL] & BIT_RAM_DL_SEL) [self reset8051];
    [self clr8:REG_SYS_FUNC_EN + 1 b:BIT(2)];
    [self wr8:REG_MCUFW_CTRL v:0];
    [self runPwrSeq:card_disable_flow_8821a];
    if (fsm & APS_FSMCO_HW_POWERDOWN) [self set16:REG_APS_FSMCO b:APS_FSMCO_HW_POWERDOWN];
}

static const u32 txscale_tbl[] = {
    0x081, 0x088, 0x090, 0x099, 0x0a2, 0x0ac, 0x0b6, 0x0c0, 0x0cc, 0x0d8,
    0x0e5, 0x0f2, 0x101, 0x110, 0x120, 0x131, 0x143, 0x156, 0x16a, 0x180,
    0x197, 0x1af, 0x1c8, 0x1e3, 0x200, 0x21e, 0x23e, 0x261, 0x285, 0x2ab,
    0x2d3, 0x2fe, 0x32b, 0x35c, 0x38e, 0x3c4, 0x3fe
};

- (u32)bbSwing:(u8)band {
    static const u32 s2s[4] = {0x200, 0x16a, 0x101, 0x0b6};
    u8 sw = (band == BAND_2G ? _ef.swing_2g : _ef.swing_5g) & 3;
    return s2s[sw];
}

- (void)switchBand:(u8)band bw:(u8)bw {
    if (!_btcoex) {
        [self wr32:REG_LED_CFG mask:BIT_DPDT_SEL_EN v:0];
        [self wr32:REG_LED_CFG mask:BIT_DPDT_WL_SEL v:1];
        [self wr32:REG_RFE_INV_A mask:0xf v:7];
        [self wr32:REG_RFE_INV_A mask:0xf0 v:7];
        [self wr32:REG_RFE_INV_A mask:BIT(29) | BIT(28) v:band == BAND_2G ? 1 : 2];
    }
    if (band == BAND_2G) {
        [self set32:REG_RXPSEL b:BIT_RX_PSEL_RST];
        [self wr32:REG_RFE_PINMUX_A mask:0xF000 v:0x7];
        [self wr32:REG_RFE_PINMUX_A mask:0xF0 v:0x7];
        [self wr32:REG_RFE_INV_A mask:BIT(20) v:_ef.ext_lna_2g ? 1 : 0];
        [self wr32:REG_RFE_INV_A mask:BIT(22) v:0];
        [self wr32:REG_RFE_PINMUX_A mask:GENMASK(2, 0) v:_ef.ext_lna_2g ? 2 : 7];
        [self wr32:REG_RFE_PINMUX_A mask:GENMASK(10, 8) v:_ef.ext_lna_2g ? 2 : 7];
        [self wr32:REG_TXSCALE_A mask:0xf00 v:0];
        [self wr32:REG_TXPSEL mask:0xf0 v:0x1];
        [self wr32:REG_CCK_RX mask:0x0f000000 v:0x1];
        u32 basic = BIT(0) | BIT(1) | BIT(2) | BIT(3) | BIT(4) | BIT(6) | BIT(8);
        [self wr32:REG_RRSR mask:0xfffff v:basic];
        [self clr8:REG_CCK_CHECK b:BIT_CHECK_CCK_EN];
    } else {
        [self wr32:REG_RFE_PINMUX_A mask:0xF000 v:0x5];
        [self wr32:REG_RFE_PINMUX_A mask:0xF0 v:0x4];
        [self wr32:REG_RFE_INV_A mask:BIT(20) v:0];
        [self wr32:REG_RFE_INV_A mask:BIT(22) v:0];
        [self wr32:REG_RFE_PINMUX_A mask:GENMASK(2, 0) v:0x7];
        [self wr32:REG_RFE_PINMUX_A mask:GENMASK(10, 8) v:0x7];
        [self set8:REG_CCK_CHECK b:BIT_CHECK_CCK_EN];
        for (int i = 0; i < 50; i++) { if (([self rd16:REG_TXPKT_EMPTY] & 0x30) == 0x30) break; udelay(50); }
        [self set32:REG_RXPSEL b:BIT_RX_PSEL_RST];
        [self wr32:REG_TXSCALE_A mask:0xf00 v:1];
        [self wr32:REG_TXPSEL mask:0xf0 v:0];
        [self wr32:REG_CCK_RX mask:0x0f000000 v:0xf];
        [self wr32:REG_RRSR mask:0xfffff v:BIT(4) | BIT(6) | BIT(8)];
    }
    [self wr32:REG_TXSCALE_A mask:BB_SWING_MASK v:[self bbSwing:band]];
    _band = band;
}

- (void)setChannel:(u8)ch bw:(u8)bw primaryIdx:(u8)pri {
    u8 newBand = ch > 14 ? BAND_5G : BAND_2G;
    if (newBand != _band) [self switchBand:newBand bw:bw];

    u32 fc;
    if (ch >= 36 && ch <= 48) fc = 0x494;
    else if (ch >= 50 && ch <= 64) fc = 0x453;
    else if (ch >= 100 && ch <= 116) fc = 0x452;
    else if (ch >= 118) fc = 0x412;
    else fc = 0x96a;
    [self wr32:REG_CLKTRK mask:0x1ffe0000 v:fc];

    u32 mod;
    if (ch >= 36 && ch <= 64) mod = 0x101;
    else if (ch >= 100 && ch <= 140) mod = 0x301;
    else if (ch > 140) mod = 0x501;
    else mod = 0;
    [self writeRF:RF_CFGCH mask:RF18_RFSI_MASK | RF18_BAND_MASK v:mod];
    [self writeRF:RF_CFGCH mask:RF18_CHANNEL_MASK v:ch];

    u16 t = [self rd16:REG_WMAC_TRXPTCL_CTL] & ~BIT_RFMOD;
    if (bw == BW_80) t |= BIT_RFMOD_80M; else if (bw == BW_40) t |= BIT_RFMOD_40M;
    [self wr16:REG_WMAC_TRXPTCL_CTL v:t];
    u8 txsc20 = pri, txsc40 = 0;
    if (bw == BW_80) txsc40 = (txsc20 == 1 || txsc20 == 3) ? 9 : 10;
    u8 txsc = BIT_TXSC_20M(txsc20) | BIT_TXSC_40M(txsc40);
    [self wr8:REG_DATA_SC v:txsc];
    u8 r837 = [self rd8:REG_BWINDICATION + 3];
    switch (bw) {
    default:
    case BW_20:
        [self wr32:REG_ADCCLK mask:0x003003C3 v:0x00300200];
        [self wr32:REG_ADC160 mask:BIT(30) v:0];
        [self wr32:REG_L1PKTH mask:0x03C00000 v:8];
        break;
    case BW_40:
        [self wr32:REG_ADCCLK mask:0x003003C3 v:0x00300201];
        [self wr32:REG_ADC160 mask:BIT(30) v:0];
        [self wr32:REG_ADCCLK mask:0x3C v:txsc];
        [self wr32:REG_CCA2ND mask:0xf0000000 v:txsc];
        [self wr32:REG_L1PKTH mask:0x03C00000 v:(r837 & BIT(2)) ? 6 : 8];
        if (txsc == 1) [self set32:REG_RXSB b:BIT(4)]; else [self clr32:REG_RXSB b:BIT(4)];
        break;
    case BW_80:
        [self wr32:REG_ADCCLK mask:0x003003C3 v:0x00300202];
        [self wr32:REG_ADC160 mask:BIT(30) v:1];
        [self wr32:REG_ADCCLK mask:0x3C v:txsc];
        [self wr32:REG_CCA2ND mask:0xf0000000 v:txsc];
        [self wr32:REG_L1PKTH mask:0x03C00000 v:(r837 & BIT(2)) ? 5 : 7];
        break;
    }
    [self writeRF:RF_CFGCH mask:RF18_BW_MASK v:bw == BW_20 ? 3 : (bw == BW_40 ? 1 : 0)];
    bool needIqk = (_iqkBand != _band || _iqkBw != bw);
    _channel = ch; _bw = bw;
    if (needIqk) { [self doIqk]; _iqkBand = _band; _iqkBw = bw; }
    [self setTxPower];
}

static int chanGroup(u8 ch, bool cck) {
    if (ch <= 2) return 0; if (ch <= 5) return 1; if (ch <= 8) return 2;
    if (ch <= 11) return 3; if (ch <= 13) return 4; if (ch == 14) return cck ? 5 : 4;
    if (ch <= 42) return 0; if (ch <= 50) return 1; if (ch <= 58) return 2;
    if (ch <= 64) return 3; if (ch <= 106) return 4; if (ch <= 114) return 5;
    if (ch <= 122) return 6; if (ch <= 130) return 7; if (ch <= 138) return 8;
    if (ch <= 144) return 9; if (ch <= 155) return 10; if (ch <= 161) return 11;
    if (ch <= 171) return 12; return 13;
}
static int nib(u8 v, int hi) { int n = hi ? (v >> 4) : (v & 0xf); return n >= 8 ? n - 16 : n; }

- (void)setTxPower {
    const u8 *m = _ef.map + 0x10;
    u8 ch = _channel;
    int cck = 0, ofdm, ht20, ht40, vht80;
    if (ch <= 14) {
        cck = m[chanGroup(ch, true)];
        int bw40 = m[6 + chanGroup(ch, false)];
        u8 d = m[11];
        ofdm = bw40 + nib(d, 0);
        ht20 = bw40 + nib(d, 1);
        ht40 = bw40;
        vht80 = ht40;
        if (cck == 0xff) cck = 0x2a;
        if (bw40 == 0xff) ofdm = ht20 = ht40 = vht80 = 0x2a;
    } else {
        const u8 *g5 = m + 18;
        int bw40 = g5[chanGroup(ch, false)];
        u8 d = g5[14];
        ofdm = bw40 + nib(d, 0);
        ht20 = bw40 + nib(d, 1);
        ht40 = bw40;
        vht80 = bw40 + nib(g5[20], 1);
        if (bw40 == 0xff) ofdm = ht20 = ht40 = vht80 = 0x2a;
    }
    int ht = _bw == BW_20 ? ht20 : (_bw == BW_40 ? ht40 : vht80);
    #define CLAMP(x) ((u32)((x) < 0 ? 0 : ((x) > 0x3f ? 0x3f : (x))))
    u32 c4 = CLAMP(cck) * 0x01010101u, o4 = CLAMP(ofdm) * 0x01010101u, h4 = CLAMP(ht) * 0x01010101u;
    if (ch <= 14) [self wr32:REG_TX_AGC_A_CCK_11_CCK_1 v:c4];
    [self wr32:REG_TX_AGC_A_CCK_11_CCK_1 + 0x04 v:o4];
    [self wr32:REG_TX_AGC_A_CCK_11_CCK_1 + 0x08 v:o4];
    [self wr32:REG_TX_AGC_A_CCK_11_CCK_1 + 0x0c v:h4];
    [self wr32:REG_TX_AGC_A_CCK_11_CCK_1 + 0x10 v:h4];
    [self wr32:REG_TX_AGC_A_CCK_11_CCK_1 + 0x1c v:h4];
    [self wr32:REG_TX_AGC_A_CCK_11_CCK_1 + 0x20 v:h4];
    [self wr32:REG_TX_AGC_A_CCK_11_CCK_1 + 0x24 mask:MASKLWORD v:h4 & 0xffff];
    int pl = CLAMP(ht), wd = 0;
    int steps[3] = {10, 8, 6};
    for (int i = 0; i < 3; i++) { pl -= steps[i]; wd |= (pl < 2 ? 2 : pl) << (i * 8); }
    [self wr32:REG_TX_PWR_TRAINING_A mask:0xffffff v:wd];
    LOG("txpwr ch%u: cck=%d ofdm=%d ht=%d", ch, cck, ofdm, ht);
}

- (void)iqk { [self doIqk]; }

static bool iqkFinish(int avg, int thr, int *xt, int *yt, int *x, int *y) {
    for (int i = 0; i < avg; i++)
        for (int ii = i + 1; ii < avg; ii++) {
            int dx = abs((xt[i] >> 21) - (xt[ii] >> 21)), dy = abs((yt[i] >> 21) - (yt[ii] >> 21));
            if (dx < thr && dy < thr) {
                *x = ((xt[i] >> 21) + (xt[ii] >> 21)) / 2;
                *y = ((yt[i] >> 21) + (yt[ii] >> 21)) / 2;
                return true;
            }
        }
    return false;
}

- (void)iqkOneShot {
    [self wr32:REG_IQK_COM64 v:0xfa000000];
    [self wr32:REG_IQK_COM64 v:0xf8000000];
    mdelay(10);
    [self wr32:REG_RFECTL_A v:0x00000000];
}

- (void)doIqk {
    static const u16 macbb[8] = {0x520, 0x550, 0x808, 0xa04, 0x90c, 0xc00, 0x838, 0x82c};
    static const u16 afe[4] = {0xc5c, 0xc60, 0xc64, 0xc68};
    static const u8 rfr[3] = {0x65, 0x8f, 0x0};
    u32 macbbB[8], afeB[4], rfB[3];
    [self wr32:REG_CCASEL mask:BIT(31) v:0];
    for (int i = 0; i < 8; i++) macbbB[i] = [self rd32:macbb[i]];
    for (int i = 0; i < 4; i++) afeB[i] = [self rd32:afe[i]];
    for (int i = 0; i < 3; i++) rfB[i] = [self readRF:rfr[i] mask:MASKDWORD];

    [self wr8:REG_TXPAUSE v:0x3f];
    [self wr32:REG_BCN_CTRL mask:(BIT_EN_BCN_FUNCTION << 8) | BIT_EN_BCN_FUNCTION v:0];
    [self wr8:REG_RXPSEL v:0x00];
    [self wr32:REG_CCA2ND mask:0xf v:0xc];
    [self wr8:REG_CCK_RX + 3 v:0xf];

    enum { CAL = 3 };
    int txX0[CAL] = {0}, txY0[CAL] = {0}, rxX0[CAL] = {0}, rxY0[CAL] = {0};
    int txAvg = 0, rxAvg = 0;
    bool tx0ok = false, rx0ok = false;
    bool is5g = _band == BAND_5G;

    for (int cal = 0; cal < CAL; cal++) {
        [self wr32:REG_CCASEL mask:BIT(31) v:0];
        [self wr32:REG_AFE_PWR1_A v:0x77777777];
        [self wr32:REG_AFE_PWR2_A v:0x77777777];
        [self wr32:REG_RX_WAIT_CCA_TX_CCK_RFON_A v:0x19791979];
        [self wr32:REG_3WIRE_SWA mask:0xf v:0x4];
        [self wr32:REG_CK_MONHA mask:GENMASK(26, 24) v:0x7];
        [self writeRF:RF_LUTWE mask:RFREG_MASK v:0x80002];
        [self writeRF:RF_CFGCH mask:0x00c00 v:0x3];
        [self writeRF:RF_MODE_TABLE_ADDR mask:RFREG_MASK v:0x20000];
        [self writeRF:RF_MODE_TABLE_DATA0 mask:RFREG_MASK v:0x0003f];
        [self writeRF:RF_MODE_TABLE_DATA1 mask:RFREG_MASK v:0xf3fc3];
        [self writeRF:RF_TXA_PREPAD mask:RFREG_MASK v:0x931d5];
        [self writeRF:RF_RXBB2 mask:RFREG_MASK v:0x8a001];
        [self wr32:REG_DAC_RSTB v:0x00008000];
        [self wr32:REG_TXAGCIDX mask:BIT(0) v:1];
        [self wr32:REG_IQK_COM00 v:0x29002000];
        [self wr32:REG_IQK_COM32 v:0xa9002000];
        [self wr32:REG_IQK_COM96 v:0x00462910];
        [self wr32:REG_CCASEL mask:BIT(31) v:1];
        [self wr32:REG_OFDM0_XB_TX_IQ_IMBALANCE v:_ef.ext_pa_5g ? 0x821403f7 : 0x821403f4];
        [self wr32:REG_TSSI_TRK_SW v:is5g ? 0x68163e96 : 0x28163e96];
        [self wr32:REG_OFDM0_XA_TX_IQ_IMBALANCE v:0x18008c10];
        [self wr32:REG_OFDM0_A_TX_AFE v:0x38008c10];
        [self wr32:REG_RFECTL_A v:0x00100000];
        [self iqkOneShot];
        [self wr32:REG_CCASEL mask:BIT(31) v:0];
        [self writeRF:RF_TXMOD mask:0x7fe00 v:[self readRF:RF_DTXLOK mask:0xffc00]];
        if (_bw == BW_40) [self writeRF:RF_CFGCH mask:RF18_BW_MASK v:1];
        else if (_bw == BW_80) [self writeRF:RF_CFGCH mask:RF18_BW_MASK v:0];

        [self writeRF:RF_LUTWE mask:RFREG_MASK v:0x80000];
        [self writeRF:RF_MODE_TABLE_ADDR mask:RFREG_MASK v:0x20000];
        [self writeRF:RF_MODE_TABLE_DATA0 mask:RFREG_MASK v:0x0003f];
        [self writeRF:RF_MODE_TABLE_DATA1 mask:RFREG_MASK v:0xf3fc3];
        [self writeRF:RF_TXA_PREPAD mask:RFREG_MASK v:0x931d5];
        [self writeRF:RF_RXBB2 mask:RFREG_MASK v:0x8a001];
        [self writeRF:RF_LUTWE mask:RFREG_MASK v:0x00000];
        [self wr32:REG_DAC_RSTB v:0x00008000];
        [self wr32:REG_TXAGCIDX mask:BIT(0) v:1];
        [self wr32:REG_IQK_COM00 v:0x29002000];
        [self wr32:REG_IQK_COM32 v:0xa9002000];
        [self wr32:REG_IQK_COM96 v:0x0046a910];
        [self wr32:REG_CCASEL mask:BIT(31) v:1];
        [self wr32:REG_OFDM0_XB_TX_IQ_IMBALANCE v:_ef.ext_pa_5g ? 0x821403f7 : 0x821403e3];
        [self wr32:REG_TSSI_TRK_SW v:is5g ? 0x40163e96 : 0x00163e96];
        [self wr32:REG_OFDM0_XA_TX_IQ_IMBALANCE v:0x18008c10];
        [self wr32:REG_OFDM0_A_TX_AFE v:0x38008c10];
        [self wr32:REG_RFECTL_A v:0x00100000];
        tx0ok = false;
        for (int retry = 0; retry < 10; retry++) {
            [self iqkOneShot];
            [self wr32:REG_RFECTL_A v:0x02000000];
            txX0[cal] = (int)([self rd32:REG_IQKA_END mask:0x07ff0000] << 21);
            [self wr32:REG_RFECTL_A v:0x04000000];
            txY0[cal] = (int)([self rd32:REG_IQKA_END mask:0x07ff0000] << 21);
            tx0ok = true;
            break;
        }
        if (!tx0ok) break;

        [self wr32:REG_CCASEL mask:BIT(31) v:0];
        [self writeRF:RF_LUTWE mask:RFREG_MASK v:0x80000];
        [self writeRF:RF_MODE_TABLE_ADDR mask:RFREG_MASK v:0x30000];
        [self writeRF:RF_MODE_TABLE_DATA0 mask:RFREG_MASK v:0x0002f];
        [self writeRF:RF_MODE_TABLE_DATA1 mask:RFREG_MASK v:0xfffbb];
        [self writeRF:RF_RXBB2 mask:RFREG_MASK v:0x88001];
        [self writeRF:RF_TXA_PREPAD mask:RFREG_MASK v:0x931d8];
        [self writeRF:RF_LUTWE mask:RFREG_MASK v:0x00000];
        [self wr32:REG_IQK_COM00 mask:0x03FF8000 v:(txX0[cal] >> 21) & 0x7ff];
        [self wr32:REG_IQK_COM00 mask:0x000007FF v:(txY0[cal] >> 21) & 0x7ff];
        [self wr32:REG_IQK_COM00 mask:BIT(31) v:1];
        [self wr32:REG_IQK_COM00 mask:BIT(31) v:0];
        [self wr32:REG_DAC_RSTB v:0x00008000];
        [self wr32:REG_IQK_COM96 v:0x0046a911];
        [self wr32:REG_CCASEL mask:BIT(31) v:1];
        [self wr32:REG_OFDM0_XA_TX_IQ_IMBALANCE v:0x38008c10];
        [self wr32:REG_OFDM0_A_TX_AFE v:0x18008c10];
        [self wr32:REG_OFDM0_XB_TX_IQ_IMBALANCE v:0x02140119];
        [self wr32:REG_TSSI_TRK_SW v:0x28160d00];
        [self wr32:REG_RFECTL_A v:0x00100000];
        rx0ok = false;
        for (int retry = 0; retry < 10; retry++) {
            [self iqkOneShot];
            if (![self rd32:REG_IQKA_END mask:BIT(11)]) {
                [self wr32:REG_RFECTL_A v:0x06000000];
                rxX0[cal] = (int)([self rd32:REG_IQKA_END mask:0x07ff0000] << 21);
                [self wr32:REG_RFECTL_A v:0x08000000];
                rxY0[cal] = (int)([self rd32:REG_IQKA_END mask:0x07ff0000] << 21);
                rx0ok = true;
                break;
            }
            [self wr32:REG_RX_IQC_AB_A mask:0x000003ff v:0x200 >> 1];
            [self wr32:REG_RX_IQC_AB_A mask:0x03ff0000 v:0];
        }
        if (tx0ok) txAvg++;
        if (rx0ok) rxAvg++;
    }

    int x = 0, y = 0;
    if (txAvg) {
        if (!iqkFinish(txAvg, 3, txX0, txY0, &x, &y)) { x = 0x200; y = 0; }
        [self wr32:REG_CCASEL mask:BIT(31) v:1];
        [self wr32:REG_LSSI_WRITE_A v:0x00000080];
        [self wr32:REG_IQK_DPD_CFG v:0x20040000];
        [self wr32:REG_CFG_PMPD v:0x20000000];
        [self wr32:REG_IQC_Y mask:0x7ff v:y];
        [self wr32:REG_IQC_X mask:0x7ff v:x];
        LOG("IQK tx x=0x%03x y=0x%03x (%d/%d ok)", x, y, txAvg, CAL);
    }
    if (rxAvg) {
        if (!iqkFinish(rxAvg, 4, rxX0, rxY0, &x, &y)) { x = 0x200; y = 0; }
        [self wr32:REG_CCASEL mask:BIT(31) v:0];
        [self wr32:REG_RX_IQC_AB_A mask:0x000003ff v:x >> 1];
        [self wr32:REG_RX_IQC_AB_A mask:0x03ff0000 v:(y >> 1) & 0x3ff];
        LOG("IQK rx x=0x%03x y=0x%03x (%d/%d ok)", x, y, rxAvg, CAL);
    }

    [self wr32:REG_CCASEL mask:BIT(31) v:0];
    for (int i = 0; i < 3; i++) [self writeRF:rfr[i] mask:RFREG_MASK v:rfB[i]];
    for (int i = 0; i < 4; i++) [self wr32:afe[i] v:afeB[i]];
    [self wr32:REG_CCASEL mask:BIT(31) v:1];
    [self wr32:REG_OFDM0_XA_TX_IQ_IMBALANCE v:0];
    [self wr32:REG_OFDM0_A_TX_AFE v:0];
    [self wr32:REG_OFDM0_XB_TX_IQ_IMBALANCE v:0];
    [self wr32:REG_TSSI_TRK_SW v:0x3c000000];
    [self wr32:REG_LSSI_WRITE_A v:0x00000080];
    [self wr32:REG_TXAGCIDX v:0];
    [self wr32:REG_IQK_DPD_CFG v:0x20040000];
    [self wr32:REG_CFG_PMPD v:0x20000000];
    [self wr32:REG_RFECTL_A v:0];
    [self wr32:REG_CCASEL mask:BIT(31) v:0];
    for (int i = 0; i < 8; i++) [self wr32:macbb[i] v:macbbB[i]];
}

- (int)epForQsel:(u8)qsel {
    int n = _usb.bulkOutCount;
    enum { EP_HI = 0, EP_NQ = 1, EP_LQ = 2, EP_EQ = 3 };
    int be, bk, vi, vo, mg, hi;
    if (n == 2) { be = bk = EP_NQ; vi = vo = mg = hi = EP_HI; }
    else if (n == 3) { be = bk = EP_LQ; vi = EP_NQ; vo = mg = hi = EP_HI; }
    else { be = bk = EP_LQ; vi = vo = EP_NQ; mg = EP_EQ; hi = EP_HI; }
    switch (qsel) {
    case 0: case 3: return be;
    case 1: case 2: return bk;
    case 4: case 5: return vi;
    case 6: case 7: return vo;
    case QSEL_MGMT: return mg;
    default: return hi;
    }
}

- (BOOL)txFrame:(const u8 *)frame len:(size_t)len opts:(rtl_tx_opts)o {
    enum { DESC = 40 };
    if (len < 10 || len > 4000) return NO;
    NSMutableData *buf = [NSMutableData dataWithLength:DESC + len];
    u8 *d = buf.mutableBytes;
    memcpy(d + DESC, frame, len);
    bool bmc = frame[4] & 1;
    u8 rate = o.rate;
    if (rate == 0xff) rate = _band == BAND_5G ? 0x04 : 0x00;
    u8 rateId = rate <= 3 ? 8 : (rate <= 0x0b ? (_band == BAND_5G ? 7 : 6) : 3);
    u32 w[10] = {0};
    w[0] = (u32)len | (DESC << 16) | (bmc ? BIT(24) : 0) | BIT(26) | (o.hwseq ? BIT(31) : 0);
    w[1] = o.macid | ((u32)o.qsel << 8) | ((u32)rateId << 16);
    w[3] = BIT(8) | (o.fallback ? 0 : BIT(10));
    w[4] = rate | (0x1f << 8);
    if (o.retry) w[4] |= ((u32)(o.retry & 0x3f) << 18) | BIT(17);
    w[8] = o.hwseq ? BIT(15) : 0;
    for (int i = 0; i < 10; i++) {
        d[i*4] = w[i]; d[i*4+1] = w[i] >> 8; d[i*4+2] = w[i] >> 16; d[i*4+3] = w[i] >> 24;
    }
    u16 ck = 0;
    for (int i = 0; i < 16; i++) ck ^= d[i*2] | d[i*2+1] << 8;
    d[28] = ck; d[29] = ck >> 8;
    return [_usb bulkOut:[self epForQsel:o.qsel] data:buf];
}

- (void)setMacAddress:(const u8 *)mac {
    for (int i = 0; i < 6; i++) [self wr8:REG_MACID + i v:mac[i]];
}

- (void)setBssid:(const u8 *)bssid {
    static const u8 zero[6] = {0};
    if (!bssid) bssid = zero;
    for (int i = 0; i < 6; i++) [self wr8:REG_BSSID + i v:bssid[i]];
}

- (void)setMonitorMode:(BOOL)on {
    u32 rcr = BIT_APP_FCS | BIT_APP_MIC | BIT_APP_ICV | BIT_APP_PHYSTS | BIT_VHT_DACK |
              BIT_HTC_LOC_CTRL | BIT_AB | BIT_AM | BIT_APM | BIT_ACRC32 | BIT_CBSSID_DATA |
              BIT_CBSSID_BCN;
    if (on) {
        rcr |= BIT_AAP | BIT_ADF | BIT_AMF;
        rcr &= ~(BIT_CBSSID_DATA | BIT_CBSSID_BCN | BIT_ACRC32);
    }
    rcr |= BIT_ADF | BIT_AMF;
    [self wr32:REG_RCR v:rcr];
    [self wr16:REG_RXFLTMAP0 v:0xffff];
    [self wr16:REG_RXFLTMAP2 v:0xffff];
}

- (void)setStationMode {
    u32 rcr = BIT_APP_FCS | BIT_APP_MIC | BIT_APP_ICV | BIT_APP_PHYSTS | BIT_VHT_DACK |
              BIT_HTC_LOC_CTRL | BIT_AB | BIT_AM | BIT_APM | BIT_CBSSID_DATA | BIT_CBSSID_BCN |
              BIT_ADF | BIT_AMF;
    [self wr32:REG_RCR v:rcr];
}

- (void)setLinked:(BOOL)linked {
    u8 msr = [self rd8:REG_CR + 2] & ~0x03;
    [self wr8:REG_CR + 2 v:msr | (linked ? 0x02 : 0x00)];
    if (linked) [self set8:REG_BCN_CTRL b:BIT_EN_BCN_FUNCTION];
}
@end
