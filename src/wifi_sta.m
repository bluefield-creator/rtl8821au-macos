#import "wifi_sta.h"
#include "rtl_rx.h"
#include "wifi_crypto.h"
#include <stdatomic.h>

#define LOG(...) do { if (self.verbose) { fprintf(stderr, "sta: " __VA_ARGS__); fputc('\n', stderr); } } while (0)
#define INFO(...) do { fprintf(stderr, "sta: " __VA_ARGS__); fputc('\n', stderr); } while (0)

static const u8 kOUI_RSN[3] = {0x00, 0x0f, 0xac};

static inline bool is_group(const u8 *a) { return a[0] & 1; }
static inline u16 get_le16(const u8 *p) { return p[0] | p[1] << 8; }
static inline u16 get_be16(const u8 *p) { return p[0] << 8 | p[1]; }
static inline u64 get_be64(const u8 *p) { u64 v = 0; for (int i = 0; i < 8; i++) v = v << 8 | p[i]; return v; }

@implementation RTLBss
- (NSString *)bssidString {
    const u8 *b = self.bssid.bytes;
    return [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4], b[5]];
}
@end

typedef void (^MgmtWaiter)(const u8 *f, size_t len);

@implementation RTLStation {
    u8 _mac[6];
    dispatch_queue_t _txq;
    NSMutableDictionary<NSData *, RTLBss *> *_scan;
    NSString *_scanSSID;

    u8 _waitSubtype;
    dispatch_semaphore_t _mgmtSem;
    NSData *_mgmtResp;

    NSString *_ssid, *_pass;
    u8 _pmk[32], _ptk[48], _anonce[32], _snonce[32];
    u8 _rsnIE[22]; size_t _rsnLen;
    u64 _replay; bool _replayValid;
    ccmp_key *_tk, *_gtk[4];
    _Atomic u64 _txPN;
    u64 _rxPN[17];
    u64 _grxPN[4];
    dispatch_semaphore_t _hsSem;
    bool _hsDone;

    u16 _lastSeq[17];

    NSDate *_lastBeacon;
    dispatch_source_t _timer;
    int _keepaliveTick;
    bool _reconnecting;
    volatile bool _scanning;
}

- (instancetype)initWithHal:(RTLHal *)hal {
    if (!(self = [super init])) return nil;
    _hal = hal;
    memcpy(_mac, hal.efuse->mac, 6);
    _txq = dispatch_queue_create("rtl.tx", DISPATCH_QUEUE_SERIAL);
    _scan = [NSMutableDictionary dictionary];
    __weak RTLStation *weak = self;
    [hal.usb startRx:^(const uint8_t *buf, size_t len) {
        RTLStation *s = weak;
        if (s) rtl_rx_parse(buf, len, rxTrampoline, (__bridge void *)s);
    }];
    return self;
}

- (const u8 *)mac { return _mac; }

static void rxTrampoline(const rtl_rx_pkt *p, void *ctx) {
    [(__bridge RTLStation *)ctx handleRx:p];
}

- (BOOL)sendMgmt:(u8)subtype to:(const u8 *)da bssid:(const u8 *)bssid body:(const u8 *)body len:(size_t)blen {
    u8 f[512];
    if (24 + blen > sizeof f) return NO;
    memset(f, 0, 24);
    f[0] = subtype;
    memcpy(f + 4, da, 6);
    memcpy(f + 10, _mac, 6);
    memcpy(f + 16, bssid, 6);
    memcpy(f + 24, body, blen);
    rtl_tx_opts o = { .qsel = QSEL_MGMT, .rate = 0xff, .hwseq = true };
    __block BOOL ok;
    u8 *fp = f;
    dispatch_sync(_txq, ^{ ok = [self->_hal txFrame:fp len:24 + blen opts:o]; });
    return ok;
}

- (u8)dataRate {
    int r = _lastRssi;
    if (r == 0) r = -70;
    if (r > -60) return 0x0b;
    if (r > -68) return 0x0a;
    if (r > -74) return 0x09;
    if (r > -80) return 0x07;
    return 0x04;
}

- (BOOL)sendData:(const u8 *)da ethertype:(u16)type payload:(const u8 *)pl len:(size_t)plen
         encrypt:(BOOL)enc lowRate:(BOOL)low {
    if (!_bss) return NO;
    u8 hdr[24] = {0};
    hdr[0] = 0x08;
    hdr[1] = 0x01;
    memcpy(hdr + 4, _bss.bssid.bytes, 6);
    memcpy(hdr + 10, _mac, 6);
    memcpy(hdr + 16, da, 6);
    size_t bodyLen = 8 + plen;
    u8 *f = malloc(24 + bodyLen + 16);
    u8 *body = malloc(bodyLen);
    static const u8 snap[6] = {0xaa, 0xaa, 0x03, 0x00, 0x00, 0x00};
    memcpy(body, snap, 6);
    body[6] = type >> 8; body[7] = type;
    memcpy(body + 8, pl, plen);
    size_t flen;
    if (enc) {
        hdr[1] |= 0x40;
        memcpy(f, hdr, 24);
        u64 pn = atomic_fetch_add(&_txPN, 1);
        flen = 24 + ccmp_encrypt(_tk, pn, 0, hdr, 24, body, bodyLen, f + 24);
    } else {
        memcpy(f, hdr, 24);
        memcpy(f + 24, body, bodyLen);
        flen = 24 + bodyLen;
    }
    free(body);
    rtl_tx_opts o = { .qsel = QSEL_BE, .rate = low ? 0xff : [self dataRate], .fallback = !low, .hwseq = true };
    __block BOOL ok;
    dispatch_sync(_txq, ^{ ok = [self->_hal txFrame:f len:flen opts:o]; });
    free(f);
    if (ok) _txData++;
    return ok;
}

- (BOOL)sendEthernet:(const u8 *)frame len:(size_t)len {
    if (_state != RTLStaConnected || len < 14) return NO;
    if (memcmp(frame + 6, _mac, 6)) return NO;
    u16 type = get_be16(frame + 12);
    return [self sendData:frame ethertype:type payload:frame + 14 len:len - 14
                  encrypt:_bss.security == RTLSecWPA2PSK lowRate:NO];
}

- (void)sendNullKeepalive {
    if (!_bss) return;
    u8 f[24] = {0x48, 0x01};
    memcpy(f + 4, _bss.bssid.bytes, 6);
    memcpy(f + 10, _mac, 6);
    memcpy(f + 16, _bss.bssid.bytes, 6);
    rtl_tx_opts o = { .qsel = QSEL_BE, .rate = 0xff, .hwseq = true };
    NSData *d = [NSData dataWithBytes:f length:24];
    dispatch_async(_txq, ^{ [self->_hal txFrame:d.bytes len:24 opts:o]; });
}

- (void)handleRx:(const rtl_rx_pkt *)p {
    if (p->is_c2h || p->crc_err || p->len < 10) return;
    const u8 *f = p->frame;
    size_t len = p->len;
    u16 fc = get_le16(f);
    u8 type = (fc >> 2) & 3;
    if (type == 0 && len >= 24) [self handleMgmt:f len:len rssi:p->rssi];
    else if (type == 2 && len >= 24) [self handleData:f len:len rssi:p->rssi];
}

- (void)parseIEs:(const u8 *)ie end:(const u8 *)end into:(RTLBss *)b {
    b.security = (b.capability & 0x0010) ? RTLSecUnsupported : RTLSecOpen;
    b.securityDesc = (b.capability & 0x0010) ? @"WEP/WPA1" : @"open";
    while (ie + 2 <= end && ie + 2 + ie[1] <= end) {
        u8 id = ie[0], l = ie[1];
        const u8 *d = ie + 2;
        if (id == 0 && l <= 32) b.ssid = [[NSString alloc] initWithBytes:d length:l encoding:NSUTF8StringEncoding] ?: @"?";
        else if (id == 1) b.rates = [NSData dataWithBytes:d length:l];
        else if (id == 50) b.extRates = [NSData dataWithBytes:d length:l];
        else if (id == 3 && l == 1) b.channel = d[0];
        else if (id == 61 && l >= 1 && !b.channel) b.channel = d[0];
        else if (id == 48 && l >= 2) {
            const u8 *q = d + 2, *e = d + l;
            bool groupCCMP = false, pairCCMP = false, akmPSK = false, akmSAE = false;
            NSMutableArray *desc = [NSMutableArray array];
            if (q + 4 <= e) { groupCCMP = !memcmp(q, kOUI_RSN, 3) && q[3] == 4; q += 4; }
            if (q + 2 <= e) {
                int n = get_le16(q); q += 2;
                for (int i = 0; i < n && q + 4 <= e; i++, q += 4)
                    if (!memcmp(q, kOUI_RSN, 3) && q[3] == 4) pairCCMP = true;
            }
            if (q + 2 <= e) {
                int n = get_le16(q); q += 2;
                for (int i = 0; i < n && q + 4 <= e; i++, q += 4) {
                    if (memcmp(q, kOUI_RSN, 3)) continue;
                    if (q[3] == 2) akmPSK = true;
                    if (q[3] == 8) akmSAE = true;
                }
            }
            if (q + 2 <= e) b.mfpRequired = (get_le16(q) & 0x40) != 0;
            if (akmPSK) [desc addObject:@"WPA2-PSK"];
            if (akmSAE) [desc addObject:@"WPA3-SAE"];
            if (!akmPSK && !akmSAE) [desc addObject:@"WPA2-Enterprise"];
            if (!groupCCMP) [desc addObject:@"TKIP-group"];
            b.securityDesc = [desc componentsJoinedByString:@"/"];
            b.security = (akmPSK && pairCCMP && groupCCMP && !b.mfpRequired) ? RTLSecWPA2PSK : RTLSecUnsupported;
        }
        ie += 2 + l;
    }
}

- (void)handleMgmt:(const u8 *)f len:(size_t)len rssi:(int)rssi {
    u8 sub = f[0] & 0xf0;
    const u8 *a1 = f + 4, *a2 = f + 10, *a3 = f + 16;

    if (sub == 0x80 || sub == 0x50) {
        if (len < 36) return;
        if (_bss && !memcmp(a3, _bss.bssid.bytes, 6)) {
            _lastBeacon = [NSDate date];
            _lastRssi = (_lastRssi * 7 + rssi) / 8;
        }
        if (_scan) {
            NSData *key = [NSData dataWithBytes:a3 length:6];
            RTLBss *b = [[RTLBss alloc] init];
            b.bssid = key;
            b.beaconInterval = get_le16(f + 32);
            b.capability = get_le16(f + 34);
            b.rssi = rssi;
            b.ssid = @"";
            [self parseIEs:f + 36 end:f + len into:b];
            if (!b.channel) b.channel = _hal.channel;
            @synchronized(_scan) {
                RTLBss *old = _scan[key];
                if (old) b.rssi = MAX(old.rssi, rssi);
                _scan[key] = b;
            }
        }
        return;
    }
    if (memcmp(a1, _mac, 6) && !is_group(a1)) return;
    if (!_bss || memcmp(a2, _bss.bssid.bytes, 6)) {
        return;
    }
    if (sub == 0xc0 || sub == 0xa0) {
        u16 reason = len >= 26 ? get_le16(f + 24) : 0;
        INFO("%s by AP (reason %u)", sub == 0xc0 ? "deauthenticated" : "disassociated", reason);
        if (_state == RTLStaConnected || _state == RTLStaHandshake) [self linkLost];
        return;
    }
    if (_waitSubtype && sub == _waitSubtype && !memcmp(a1, _mac, 6)) {
        _mgmtResp = [NSData dataWithBytes:f length:len];
        _waitSubtype = 0;
        dispatch_semaphore_signal(_mgmtSem);
    }
}

- (nullable NSData *)mgmtExchange:(u8)reqSub body:(const u8 *)body len:(size_t)blen
                         waitFor:(u8)respSub tries:(int)tries timeout:(double)to {
    const u8 *bssid = _bss.bssid.bytes;
    for (int t = 0; t < tries; t++) {
        _mgmtSem = dispatch_semaphore_create(0);
        _mgmtResp = nil;
        _waitSubtype = respSub;
        [self sendMgmt:reqSub to:bssid bssid:bssid body:body len:blen];
        if (dispatch_semaphore_wait(_mgmtSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(to * NSEC_PER_SEC))) == 0)
            return _mgmtResp;
        LOG("no response to subtype 0x%02x (try %d)", reqSub, t + 1);
    }
    _waitSubtype = 0;
    return nil;
}

- (void)sendProbe:(nullable NSString *)ssid {
    u8 body[64]; size_t n = 0;
    NSData *s = [ssid dataUsingEncoding:NSUTF8StringEncoding];
    body[n++] = 0; body[n++] = (u8)MIN(s.length, 32);
    memcpy(body + n, s.bytes, MIN(s.length, 32)); n += MIN(s.length, 32);
    if (_hal.channel <= 14) {
        static const u8 r[] = {1, 8, 0x82, 0x84, 0x8b, 0x96, 0x0c, 0x12, 0x18, 0x24, 50, 4, 0x30, 0x48, 0x60, 0x6c};
        memcpy(body + n, r, sizeof r); n += sizeof r;
    } else {
        static const u8 r[] = {1, 8, 0x8c, 0x12, 0x98, 0x24, 0xb0, 0x48, 0x60, 0x6c};
        memcpy(body + n, r, sizeof r); n += sizeof r;
    }
    static const u8 bc[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    [self sendMgmt:0x40 to:bc bssid:bc body:body len:n];
}

- (NSArray<RTLBss *> *)scanForSSID:(NSString *)ssid dwell:(double)dwell include5GHz:(BOOL)five {
    if (!_scan) _scan = [NSMutableDictionary dictionary];
    _scanning = true;
    @synchronized(_scan) { [_scan removeAllObjects]; }
    [_hal setMonitorMode:YES];
    NSMutableArray *chans = [NSMutableArray array];
    for (int c = 1; c <= 13; c++) [chans addObject:@(c)];
    if (five) for (NSNumber *c in @[@36, @40, @44, @48, @52, @56, @60, @64, @100, @104, @108,
                                    @112, @116, @120, @124, @128, @132, @136, @140]) [chans addObject:c];
    for (NSNumber *c in chans) {
        u8 ch = c.unsignedCharValue;
        [_hal setChannel:ch bw:BW_20 primaryIdx:0];
        bool active = ch <= 13 || (ch >= 36 && ch <= 48);
        if (active) { [self sendProbe:ssid]; [NSThread sleepForTimeInterval:dwell / 2]; [self sendProbe:ssid]; [NSThread sleepForTimeInterval:dwell / 2]; }
        else [NSThread sleepForTimeInterval:dwell * 1.5];
    }
    NSArray *all;
    @synchronized(_scan) { all = _scan.allValues; }
    if (_bss && (_state == RTLStaConnected || _state == RTLStaHandshake)) {
        [_hal setChannel:_bss.channel bw:BW_20 primaryIdx:0];
        [_hal setBssid:_bss.bssid.bytes];
        [_hal setStationMode];
        _lastBeacon = [NSDate date];
    }
    _scanning = false;
    return [all sortedArrayUsingComparator:^NSComparisonResult(RTLBss *a, RTLBss *b) {
        return a.rssi > b.rssi ? NSOrderedAscending : (a.rssi < b.rssi ? NSOrderedDescending : NSOrderedSame);
    }];
}

- (NSError *)err:(NSString *)msg {
    return [NSError errorWithDomain:@"rtl8821au" code:10 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

- (void)resetKeys {
    ccmp_key_free(_tk); _tk = NULL;
    for (int i = 0; i < 4; i++) { ccmp_key_free(_gtk[i]); _gtk[i] = NULL; }
    memset(_rxPN, 0, sizeof _rxPN);
    memset(_grxPN, 0, sizeof _grxPN);
    memset(_lastSeq, 0xff, sizeof _lastSeq);
    atomic_store(&_txPN, 1);
    _replayValid = false;
    _hsDone = false;
}

- (BOOL)connectToSSID:(NSString *)ssid passphrase:(NSString *)pass error:(NSError **)error {
    _ssid = ssid; _pass = pass;
    [self disconnectQuiet];

    INFO("scanning for \"%s\"...", ssid.UTF8String);
    NSArray<RTLBss *> *res = [self scanForSSID:ssid dwell:0.12 include5GHz:YES];
    RTLBss *pick = nil;
    for (RTLBss *b in res) if ([b.ssid isEqualToString:ssid]) { pick = b; break; }
    if (!pick) { if (error) *error = [self err:@"network not found"]; return NO; }
    INFO("found %s on channel %u (%d dBm, %s)", pick.bssidString.UTF8String, pick.channel, pick.rssi,
         pick.securityDesc.UTF8String);
    if (pick.security == RTLSecUnsupported) {
        if (error) *error = [self err:[NSString stringWithFormat:@"unsupported security: %@", pick.securityDesc]];
        return NO;
    }
    return [self joinBss:pick passphrase:pass error:error];
}

- (BOOL)joinBss:(RTLBss *)b passphrase:(NSString *)pass error:(NSError **)error {
    [self disconnectQuiet];
    _ssid = b.ssid; _pass = pass;
    if (b.security == RTLSecUnsupported) {
        if (error) *error = [self err:[NSString stringWithFormat:@"unsupported security: %@", b.securityDesc]];
        return NO;
    }
    if (b.security == RTLSecWPA2PSK) {
        if (pass.length < 8 || pass.length > 63) { if (error) *error = [self err:@"WPA2 passphrase must be 8-63 characters"]; return NO; }
        NSData *s = [b.ssid dataUsingEncoding:NSUTF8StringEncoding];
        wpa_pmk(pass.UTF8String, s.bytes, s.length, _pmk);
    }
    return [self joinBss:b error:error];
}

- (void)shutdown {
    _autoReconnect = NO;
    [self stopSupervision];
    self.onEthernet = nil;
    self.onLinkChange = nil;
    _state = RTLStaIdle;
    _bss = nil;
}

- (BOOL)joinBss:(RTLBss *)b error:(NSError **)error {
    @synchronized(_scan) { _scan = nil; }
    [self resetKeys];
    _bss = b;
    _lastRssi = b.rssi;
    [_hal setChannel:b.channel bw:BW_20 primaryIdx:0];
    [_hal setBssid:b.bssid.bytes];
    [_hal setStationMode];

    _state = RTLStaAuth;
    u8 auth[6] = {0, 0, 1, 0, 0, 0};
    NSData *r = [self mgmtExchange:0xb0 body:auth len:6 waitFor:0xb0 tries:4 timeout:0.3];
    if (!r || r.length < 30) { [self abortJoin]; if (error) *error = [self err:@"authentication timed out"]; return NO; }
    const u8 *rb = (const u8 *)r.bytes + 24;
    if (get_le16(rb + 4) != 0) {
        [self abortJoin];
        if (error) *error = [self err:[NSString stringWithFormat:@"authentication rejected (status %u)", get_le16(rb + 4)]];
        return NO;
    }
    LOG("authenticated");

    _state = RTLStaAssoc;
    u8 body[256]; size_t n = 0;
    u16 cap = 0x0001 | (b.capability & (0x0010 | 0x0020 | 0x0400));
    body[n++] = cap; body[n++] = cap >> 8;
    body[n++] = 10; body[n++] = 0;
    NSData *s = [b.ssid dataUsingEncoding:NSUTF8StringEncoding];
    body[n++] = 0; body[n++] = s.length; memcpy(body + n, s.bytes, s.length); n += s.length;
    body[n++] = 1; body[n++] = b.rates.length; memcpy(body + n, b.rates.bytes, b.rates.length); n += b.rates.length;
    if (b.extRates.length) {
        body[n++] = 50; body[n++] = b.extRates.length; memcpy(body + n, b.extRates.bytes, b.extRates.length); n += b.extRates.length;
    }
    if (b.security == RTLSecWPA2PSK) {
        static const u8 rsn[22] = {48, 20, 1, 0, 0x00, 0x0f, 0xac, 4, 1, 0, 0x00, 0x0f, 0xac, 4,
                                   1, 0, 0x00, 0x0f, 0xac, 2, 0, 0};
        memcpy(_rsnIE, rsn, 22); _rsnLen = 22;
        memcpy(body + n, rsn, 22); n += 22;
    }
    _hsSem = dispatch_semaphore_create(0);
    if (b.security == RTLSecWPA2PSK) _state = RTLStaHandshake;
    r = [self mgmtExchange:0x00 body:body len:n waitFor:0x10 tries:4 timeout:0.4];
    if (!r || r.length < 30) { [self abortJoin]; if (error) *error = [self err:@"association timed out"]; return NO; }
    rb = (const u8 *)r.bytes + 24;
    u16 status = get_le16(rb + 2), aid = get_le16(rb + 4) & 0x3fff;
    if (status != 0) {
        [self abortJoin];
        if (error) *error = [self err:[NSString stringWithFormat:@"association rejected (status %u)", status]];
        return NO;
    }
    LOG("associated, AID %u", aid);
    [_hal setLinked:YES];
    _lastBeacon = [NSDate date];

    if (b.security == RTLSecWPA2PSK) {
        if (dispatch_semaphore_wait(_hsSem, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) || !_hsDone) {
            [self deauth:15];
            if (error) *error = [self err:@"4-way handshake failed (wrong password?)"];
            return NO;
        }
    }
    _state = RTLStaConnected;
    INFO("connected to \"%s\" (%s, ch %u)", b.ssid.UTF8String, b.bssidString.UTF8String, b.channel);
    [self startSupervision];
    if (self.onLinkChange) self.onLinkChange(YES);
    return YES;
}

- (void)abortJoin {
    _state = RTLStaIdle;
    _bss = nil;
    [_hal setLinked:NO];
    [_hal setBssid:NULL];
    @synchronized(self) { if (!_scan) _scan = [NSMutableDictionary dictionary]; }
}

- (void)deauth:(u16)reason {
    if (_bss) {
        u8 body[2] = {reason, reason >> 8};
        [self sendMgmt:0xc0 to:_bss.bssid.bytes bssid:_bss.bssid.bytes body:body len:2];
    }
    [self abortJoin];
    [self resetKeys];
}

- (void)disconnectQuiet {
    [self stopSupervision];
    if (_state != RTLStaIdle) [self deauth:3];
}

- (void)disconnect {
    BOOL was = _state == RTLStaConnected;
    _autoReconnect = NO;
    [self disconnectQuiet];
    if (was && self.onLinkChange) self.onLinkChange(NO);
}

- (void)startSupervision {
    [self stopSupervision];
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    __weak RTLStation *weak = self;
    dispatch_source_set_event_handler(_timer, ^{ [weak tick]; });
    dispatch_resume(_timer);
}

- (void)stopSupervision {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
}

- (void)tick {
    if (_state != RTLStaConnected || _scanning) return;
    if (++_keepaliveTick % 15 == 0) [self sendNullKeepalive];
    if (-[_lastBeacon timeIntervalSinceNow] > 8.0) {
        INFO("lost beacons from AP");
        [self linkLost];
    }
}

- (void)linkLost {
    if (_reconnecting) return;
    [self stopSupervision];
    BOOL was = _state == RTLStaConnected;
    [self abortJoin];
    [self resetKeys];
    if (was && self.onLinkChange) self.onLinkChange(NO);
    if (!_autoReconnect) return;
    _reconnecting = true;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int attempt = 1; self->_autoReconnect; attempt++) {
            [NSThread sleepForTimeInterval:MIN(attempt, 10)];
            INFO("reconnecting (attempt %d)...", attempt);
            NSError *e = nil;
            if ([self connectToSSID:self->_ssid passphrase:self->_pass error:&e]) break;
            INFO("reconnect failed: %s", e.localizedDescription.UTF8String);
        }
        self->_reconnecting = false;
    });
}

- (void)handleData:(const u8 *)f len:(size_t)len rssi:(int)rssi {
    if (!_bss) return;
    u16 fc = get_le16(f);
    u8 ds = (fc >> 8) & 3;
    if (ds != 2) return;
    const u8 *a1 = f + 4, *a2 = f + 10, *a3 = f + 16;
    if (memcmp(a2, _bss.bssid.bytes, 6)) return;
    if (!is_group(a1) && memcmp(a1, _mac, 6)) return;
    u8 sub = (fc >> 4) & 0xf;
    if (sub & 0x4) return;
    bool qos = sub & 0x8;
    size_t hl = 24 + (qos ? 2 : 0) + ((qos && (fc & 0x8000)) ? 4 : 0);
    if (len < hl + 8) return;
    _lastRssi = (_lastRssi * 7 + rssi) / 8;
    _lastBeacon = [NSDate date];

    u8 tid = qos ? (f[24] & 0x0f) : 16;
    u16 seqctl = get_le16(f + 22);
    if (!is_group(a1)) {
        if ((fc & 0x0800) && _lastSeq[tid] == seqctl) { _rxDropped++; return; }
        _lastSeq[tid] = seqctl;
    }

    const u8 *body = f + hl;
    size_t blen = len - hl;
    u8 *plain = NULL;
    if (fc & 0x4000) {
        if (blen < 16) return;
        u8 keyid = body[3] >> 6;
        ccmp_key *k = is_group(a1) ? _gtk[keyid] : _tk;
        if (!k) { _rxDropped++; return; }
        plain = malloc(blen);
        u64 pn = 0;
        long pl = ccmp_decrypt(k, f, hl, body, blen, plain, &pn);
        if (pl < 0) { free(plain); _micFailures++; LOG("CCMP MIC failure"); return; }
        u64 *last = is_group(a1) ? &_grxPN[keyid] : &_rxPN[tid];
        if (pn <= *last) { free(plain); _rxDropped++; return; }
        *last = pn;
        body = plain; blen = pl;
    } else if (_bss.security == RTLSecWPA2PSK) {
        if (!(blen >= 8 && body[6] == 0x88 && body[7] == 0x8e)) { _rxDropped++; return; }
    }

    if (blen >= 8 && body[0] == 0xaa && body[1] == 0xaa && body[2] == 0x03 &&
        body[3] == 0 && body[4] == 0 && (body[5] == 0 || body[5] == 0xf8)) {
        u16 type = get_be16(body + 6);
        if (type == 0x888e) { [self handleEapol:body + 8 len:blen - 8]; free(plain); return; }
        if (_state == RTLStaConnected && memcmp(a3, _mac, 6)) {
            size_t elen = 14 + blen - 8;
            u8 *eth = malloc(elen);
            memcpy(eth, a1, 6);
            memcpy(eth + 6, a3, 6);
            memcpy(eth + 12, body + 6, 2);
            memcpy(eth + 14, body + 8, blen - 8);
            _rxData++;
            if (self.onEthernet) self.onEthernet(eth, elen);
            free(eth);
        }
    }
    free(plain);
}

enum {
    KI_VER_MASK = 0x0007, KI_PAIRWISE = 0x0008, KI_INSTALL = 0x0040, KI_ACK = 0x0080,
    KI_MIC = 0x0100, KI_SECURE = 0x0200, KI_ERROR = 0x0400, KI_REQUEST = 0x0800, KI_ENC = 0x1000,
};
#define EK_INFO     5
#define EK_REPLAY   9
#define EK_NONCE    17
#define EK_MIC      81
#define EK_KDLEN    97
#define EK_DATA     99

- (void)sendEapolKey:(u16)info nonce:(const u8 *)nonce data:(const u8 *)kd len:(size_t)kdlen {
    size_t blen = EK_DATA + kdlen;
    u8 *e = calloc(1, blen);
    e[0] = 1;
    e[1] = 3;
    e[2] = (blen - 4) >> 8; e[3] = blen - 4;
    e[4] = 2;
    e[EK_INFO] = info >> 8; e[EK_INFO + 1] = info;
    for (int i = 0; i < 8; i++) e[EK_REPLAY + i] = _replay >> (8 * (7 - i));
    if (nonce) memcpy(e + EK_NONCE, nonce, 32);
    e[EK_KDLEN] = kdlen >> 8; e[EK_KDLEN + 1] = kdlen;
    if (kdlen) memcpy(e + EK_DATA, kd, kdlen);
    wpa_eapol_mic(_ptk, e, blen, e + EK_MIC);
    [self sendData:_bss.bssid.bytes ethertype:0x888e payload:e len:blen
           encrypt:(_tk != NULL) lowRate:YES];
    free(e);
}

- (BOOL)verifyMic:(const u8 *)e len:(size_t)len {
    u8 *c = malloc(len), mic[16];
    memcpy(c, e, len);
    memset(c + EK_MIC, 0, 16);
    wpa_eapol_mic(_ptk, c, len, mic);
    free(c);
    return !memcmp(mic, e + EK_MIC, 16);
}

- (BOOL)installGtkFrom:(const u8 *)kd len:(size_t)kdlen {
    const u8 *p = kd, *end = kd + kdlen;
    while (p + 2 <= end) {
        if (p[0] == 0xdd && p[1] >= 6 && p + 2 + p[1] <= end && !memcmp(p + 2, kOUI_RSN, 3) && p[5] == 1) {
            u8 keyid = p[6] & 3;
            size_t glen = p[1] - 6;
            if (glen != 16) { INFO("unsupported GTK length %zu", glen); return NO; }
            ccmp_key_free(_gtk[keyid]);
            _gtk[keyid] = ccmp_key_new(p + 8);
            _grxPN[keyid] = 0;
            LOG("installed GTK (key id %u)", keyid);
            return YES;
        }
        if (p[0] == 0xdd && p[1] == 0) break;
        p += 2 + p[1];
    }
    return NO;
}

- (void)handleEapol:(const u8 *)e len:(size_t)len {
    if (_bss.security != RTLSecWPA2PSK || len < EK_DATA || e[1] != 3 || e[4] != 2) return;
    size_t blen = MIN(len, (size_t)(4 + get_be16(e + 2)));
    u16 info = get_be16(e + EK_INFO);
    u64 replay = get_be64(e + EK_REPLAY);
    size_t kdlen = get_be16(e + EK_KDLEN);
    if (EK_DATA + kdlen > blen) return;
    if ((info & KI_VER_MASK) != 2) { INFO("unsupported key descriptor version %u", info & KI_VER_MASK); return; }
    if (_replayValid && replay <= _replay && (info & KI_MIC)) { LOG("EAPOL replay"); return; }
    const u8 *bssid = _bss.bssid.bytes;

    if ((info & KI_PAIRWISE) && (info & KI_ACK) && !(info & KI_MIC)) {
        LOG("EAPOL 1/4");
        memcpy(_anonce, e + EK_NONCE, 32);
        arc4random_buf(_snonce, 32);
        wpa_ptk(_pmk, bssid, _mac, _anonce, _snonce, _ptk);
        _replay = replay; _replayValid = true;
        [self sendEapolKey:2 | KI_PAIRWISE | KI_MIC nonce:_snonce data:_rsnIE len:_rsnLen];
        LOG("sent EAPOL 2/4");
        return;
    }
    if ((info & KI_PAIRWISE) && (info & KI_ACK) && (info & KI_MIC) && (info & KI_INSTALL)) {
        LOG("EAPOL 3/4");
        if (memcmp(_anonce, e + EK_NONCE, 32)) { INFO("ANonce changed in 3/4"); return; }
        if (![self verifyMic:e len:blen]) { INFO("EAPOL 3/4 MIC mismatch — wrong password?"); return; }
        _replay = replay;
        u8 kd[512];
        int kl = -1;
        if (info & KI_ENC) kl = wpa_aes_unwrap(_ptk + 16, e + EK_DATA, kdlen, kd);
        if (kl < 0 || ![self installGtkFrom:kd len:kl]) { INFO("could not extract GTK from 3/4"); return; }
        [self sendEapolKey:2 | KI_PAIRWISE | KI_MIC | KI_SECURE nonce:NULL data:NULL len:0];
        LOG("sent EAPOL 4/4");
        ccmp_key_free(_tk);
        _tk = ccmp_key_new(_ptk + 32);
        _hsDone = true;
        if (_hsSem) dispatch_semaphore_signal(_hsSem);
        return;
    }
    if (!(info & KI_PAIRWISE) && (info & KI_ACK) && (info & KI_MIC)) {
        if (![self verifyMic:e len:blen]) { INFO("group key MIC mismatch"); return; }
        _replay = replay;
        u8 kd[512];
        int kl = wpa_aes_unwrap(_ptk + 16, e + EK_DATA, kdlen, kd);
        if (kl < 0 || ![self installGtkFrom:kd len:kl]) { INFO("bad group key message"); return; }
        [self sendEapolKey:2 | KI_MIC | KI_SECURE nonce:NULL data:NULL len:0];
        INFO("group key updated");
    }
}
@end
