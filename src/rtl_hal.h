// Ported from Linux rtw88 (rtw88xxa.c / rtw8821a.c / mac.c / phy.c),
// Copyright(c) 2018-2024 Realtek Corporation, used under BSD-3-Clause.
#pragma once
#import "rtl_usb.h"

NS_ASSUME_NONNULL_BEGIN

enum { BAND_2G = 0, BAND_5G = 1 };
enum { BW_20 = 0, BW_40 = 1, BW_80 = 2 };

typedef struct {
    u8 map[512];
    u8 mac[6];
    u8 crystal_cap, thermal, pa_type, lna_type_2g, lna_type_5g;
    u8 rfe_option, board_option, bt_setting;
    u8 swing_2g, swing_5g;
    bool ext_pa_2g, ext_lna_2g, ext_pa_5g, ext_lna_5g;
    u8 gpa_type, apa_type, glna_type, alna_type;
} rtw_efuse_t;

@interface RTLHal : NSObject
@property(readonly) RTLUSB *usb;
@property(readonly) rtw_efuse_t *efuse;
@property(readonly) u8 cut;
@property(readonly) bool btcoex;
@property(readonly) u8 channel, band, bw;
@property(nonatomic) bool verbose;

- (instancetype)initWithUSB:(RTLUSB *)usb;

- (BOOL)readEfuse;
- (BOOL)powerOnWithFirmware:(NSData *)fw;
- (void)powerOff;
- (void)setChannel:(u8)ch bw:(u8)bw primaryIdx:(u8)pri;
- (void)setTxPower;
- (void)iqk;

- (void)setMacAddress:(const u8 *)mac;
- (void)setBssid:(const u8 *_Nullable)bssid;
- (void)setMonitorMode:(BOOL)on;
- (void)setStationMode;
- (void)setLinked:(BOOL)linked;

enum { QSEL_BE = 0, QSEL_BK = 1, QSEL_VI = 4, QSEL_VO = 6, QSEL_HIGH = 17, QSEL_MGMT = 18 };
typedef struct {
    u8 qsel;
    u8 rate;
    bool fallback;
    bool hwseq;
    u8 macid;
    u8 retry;
} rtl_tx_opts;
- (BOOL)txFrame:(const u8 *)frame len:(size_t)len opts:(rtl_tx_opts)o;

- (u8)rd8:(u16)a;  - (u16)rd16:(u16)a;  - (u32)rd32:(u16)a;
- (void)wr8:(u16)a v:(u8)v;  - (void)wr16:(u16)a v:(u16)v;  - (void)wr32:(u16)a v:(u32)v;
- (void)wr32:(u16)a mask:(u32)m v:(u32)v;
- (u32)rd32:(u16)a mask:(u32)m;
- (u32)readRF:(u32)addr mask:(u32)m;
- (void)writeRF:(u32)addr mask:(u32)m v:(u32)v;
@end

NS_ASSUME_NONNULL_END
