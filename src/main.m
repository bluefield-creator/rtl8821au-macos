#import <Foundation/Foundation.h>
#import "rtl_usb.h"
#import "rtl_hal.h"
#import "wifi_sta.h"
#import "netif.h"
#include "rtl_rx.h"
#include "wifi_crypto.h"
#include <signal.h>

NSData *rtl_load_firmware(void) {
    NSString *exe = [[NSProcessInfo processInfo].arguments[0] stringByResolvingSymlinksInPath];
    NSArray *candidates = @[
        [[exe stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"firmware/rtw8821a_fw.bin"],
        [[exe stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"rtw8821a_fw.bin"],
        @"firmware/rtw8821a_fw.bin",
        @"/usr/local/share/rtl8821au/rtw8821a_fw.bin",
    ];
    for (NSString *p in candidates) {
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (d) return d;
    }
    fprintf(stderr, "firmware rtw8821a_fw.bin not found\n");
    return nil;
}

typedef struct { int frames, beacons, crc; NSMutableDictionary *seen; } sniff_ctx;

static void onSniff(const rtl_rx_pkt *p, void *vctx) {
    sniff_ctx *c = vctx;
    c->frames++;
    if (p->is_c2h) return;
    if (p->crc_err) { c->crc++; return; }
    if (p->len < 36) return;
    const u8 *f = p->frame;
    if ((f[0] & 0xfc) != 0x80) return;
    c->beacons++;
    const u8 *bssid = f + 16;
    NSString *key = [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
                     bssid[0], bssid[1], bssid[2], bssid[3], bssid[4], bssid[5]];
    c->seen[key] = @([c->seen[key] intValue] + 1);
}

static int cmdSniff(RTLHal *hal, int argc, char **argv) {
    NSMutableArray<NSNumber *> *chans = [NSMutableArray array];
    double dwell = 0.3;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "-t") && i + 1 < argc) dwell = atof(argv[++i]);
        else [chans addObject:@(atoi(argv[i]))];
    }
    if (!chans.count) for (int ch = 1; ch <= 13; ch++) [chans addObject:@(ch)];
    __block sniff_ctx ctx = { .seen = [NSMutableDictionary dictionary] };
    [hal setMonitorMode:YES];
    [hal.usb startRx:^(const uint8_t *buf, size_t len) { rtl_rx_parse(buf, len, onSniff, &ctx); }];
    for (NSNumber *ch in chans) {
        [hal setChannel:ch.unsignedCharValue bw:BW_20 primaryIdx:0];
        [NSThread sleepForTimeInterval:dwell];
    }
    [hal.usb stopRx];
    for (NSString *k in ctx.seen) printf("  %s: %d beacons\n", k.UTF8String, [ctx.seen[k] intValue]);
    printf("%d frames, %d beacons, %d CRC errors, %lu BSSIDs\n",
           ctx.frames, ctx.beacons, ctx.crc, (unsigned long)ctx.seen.count);
    return ctx.beacons ? 0 : 2;
}

static int cmdScan(RTLHal *hal, int argc, char **argv) {
    BOOL five = YES;
    for (int i = 0; i < argc; i++) if (!strcmp(argv[i], "-2")) five = NO;
    RTLStation *sta = [[RTLStation alloc] initWithHal:hal];
    NSArray<RTLBss *> *res = [sta scanForSSID:nil dwell:0.15 include5GHz:five];
    printf("%-17s  %4s  %8s  %-22s  %s\n", "BSSID", "CH", "SIGNAL", "SECURITY", "SSID");
    for (RTLBss *b in res)
        printf("%-17s  %4u  %4d dBm  %-22s  %s%s\n", b.bssidString.UTF8String, b.channel, b.rssi,
               b.securityDesc.UTF8String, b.ssid.length ? b.ssid.UTF8String : "<hidden>",
               b.security == RTLSecUnsupported ? "  (unsupported)" : "");
    printf("%lu networks\n", (unsigned long)res.count);
    return 0;
}

static u16 ipsum(const u8 *p, size_t n) {
    u32 s = 0;
    for (size_t i = 0; i + 1 < n; i += 2) s += p[i] << 8 | p[i + 1];
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return ~s;
}

static size_t buildDhcpDiscover(u8 *f, const u8 *mac, u32 xid) {
    memset(f, 0, 342);
    memset(f, 0xff, 6); memcpy(f + 6, mac, 6); f[12] = 0x08; f[13] = 0x00;
    u8 *ip = f + 14, *udp = ip + 20, *bp = udp + 8;
    bp[0] = 1; bp[1] = 1; bp[2] = 6;
    bp[4] = xid >> 24; bp[5] = xid >> 16; bp[6] = xid >> 8; bp[7] = xid;
    bp[10] = 0x80;
    memcpy(bp + 28, mac, 6);
    u8 *o = bp + 236;
    *o++ = 99; *o++ = 130; *o++ = 83; *o++ = 99;
    *o++ = 53; *o++ = 1; *o++ = 1;
    *o++ = 55; *o++ = 4; *o++ = 1; *o++ = 3; *o++ = 6; *o++ = 51;
    *o++ = 255;
    size_t bplen = 300;
    u16 ulen = 8 + bplen, tlen = 20 + ulen;
    udp[0] = 0; udp[1] = 68; udp[2] = 0; udp[3] = 67; udp[4] = ulen >> 8; udp[5] = ulen;
    ip[0] = 0x45; ip[2] = tlen >> 8; ip[3] = tlen; ip[8] = 64; ip[9] = 17;
    memset(ip + 16, 0xff, 4);
    u16 c = ipsum(ip, 20); ip[10] = c >> 8; ip[11] = c;
    return 14 + tlen;
}

static NSString *ipstr(const u8 *p) { return [NSString stringWithFormat:@"%u.%u.%u.%u", p[0], p[1], p[2], p[3]]; }

static NSString *parseDhcpOffer(const u8 *f, size_t len, u32 xid) {
    if (len < 14 + 20 + 8 + 240 || f[12] != 0x08 || f[13] != 0x00) return nil;
    const u8 *ip = f + 14;
    size_t ihl = (ip[0] & 0xf) * 4;
    if (ip[9] != 17) return nil;
    const u8 *udp = ip + ihl, *bp = udp + 8;
    if (udp[1] != 67 || udp[3] != 68) return nil;
    if (bp[0] != 2 || (u32)(bp[4] << 24 | bp[5] << 16 | bp[6] << 8 | bp[7]) != xid) return nil;
    NSMutableString *s = [NSMutableString stringWithFormat:@"offered %@", ipstr(bp + 16)];
    const u8 *o = bp + 240, *end = f + len;
    while (o < end && *o != 255) {
        if (*o == 0) { o++; continue; }
        if (o + 2 > end || o + 2 + o[1] > end) break;
        if (o[0] == 1 && o[1] == 4) [s appendFormat:@", mask %@", ipstr(o + 2)];
        if (o[0] == 3 && o[1] >= 4) [s appendFormat:@", router %@", ipstr(o + 2)];
        if (o[0] == 6 && o[1] >= 4) [s appendFormat:@", DNS %@", ipstr(o + 2)];
        if (o[0] == 54 && o[1] == 4) [s appendFormat:@", server %@", ipstr(o + 2)];
        o += 2 + o[1];
    }
    return s;
}

static NSString *getPassphrase(int argc, char **argv, int *ai) {
    for (int i = 0; i < argc; i++)
        if ((!strcmp(argv[i], "-p")) && i + 1 < argc) return @(argv[i + 1]);
    const char *env = getenv("RTL_PSK");
    if (env) return @(env);
    if (isatty(0)) { char *p = getpass("Passphrase (empty for open network): "); if (p && *p) return @(p); }
    return nil;
}

static int cmdConnect(RTLHal *hal, int argc, char **argv, BOOL verbose) {
    if (argc < 1) { fprintf(stderr, "usage: connect <ssid> [-p passphrase]\n"); return 1; }
    NSString *ssid = @(argv[0]);
    NSString *pass = getPassphrase(argc - 1, argv + 1, NULL);
    RTLStation *sta = [[RTLStation alloc] initWithHal:hal];
    sta.verbose = verbose;
    NSError *err = nil;
    NSDate *t0 = [NSDate date];
    if (![sta connectToSSID:ssid passphrase:pass error:&err]) {
        fprintf(stderr, "connect failed: %s\n", err.localizedDescription.UTF8String);
        return 2;
    }
    printf("Connected in %.2fs. Testing the data path with a DHCP discover...\n", -t0.timeIntervalSinceNow);

    u32 xid = arc4random();
    __block NSString *offer = nil;
    __block int rxFrames = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    sta.onEthernet = ^(const u8 *f, size_t len) {
        rxFrames++;
        NSString *o = parseDhcpOffer(f, len, xid);
        if (o && !offer) { offer = o; dispatch_semaphore_signal(sem); }
    };
    u8 f[400];
    size_t n = buildDhcpDiscover(f, sta.mac, xid);
    for (int i = 0; i < 4 && !offer; i++) {
        [sta sendEthernet:f len:n];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
    if (offer) printf("DHCP: %s\n", offer.UTF8String);
    else printf("No DHCP offer received.\n");
    printf("RSSI %d dBm, %llu data frames in (%d delivered), %llu out, %llu MIC failures\n",
           sta.lastRssi, sta.rxData, rxFrames, sta.txData, sta.micFailures);
    [sta disconnect];
    return offer ? 0 : 3;
}

static volatile sig_atomic_t gStop = 0;
static void onSignal(int s) { gStop = 1; }

static int cmdUp(RTLHal *hal, int argc, char **argv, BOOL verbose) {
    if (argc < 1) { fprintf(stderr, "usage: up <ssid> [-p passphrase]\n"); return 1; }
    NSString *ssid = @(argv[0]);
    NSString *pass = getPassphrase(argc - 1, argv + 1, NULL);
    NSError *err = nil;
    RTLNetif *nif = [[RTLNetif alloc] initWithMAC:hal.efuse->mac error:&err];
    if (!nif) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }

    RTLStation *sta = [[RTLStation alloc] initWithHal:hal];
    sta.verbose = verbose;
    sta.autoReconnect = YES;
    __weak RTLNetif *wnif = nif;
    sta.onEthernet = ^(const u8 *f, size_t len) { [wnif inject:f len:len]; };
    sta.onLinkChange = ^(BOOL up) {
        printf("link %s\n", up ? "up" : "down");
        [wnif setLinkUp:up];
    };
    __weak RTLStation *wsta = sta;
    nif.onFrame = ^(const u8 *f, size_t len) { [wsta sendEthernet:f len:len]; };
    [nif start];

    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);
    if (![sta connectToSSID:ssid passphrase:pass error:&err]) {
        fprintf(stderr, "connect failed: %s (will keep retrying)\n", err.localizedDescription.UTF8String);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSError *e;
            for (int i = 1; !gStop && wsta.state != RTLStaConnected; i++) {
                [NSThread sleepForTimeInterval:MIN(i * 2, 15)];
                if (![wsta connectToSSID:ssid passphrase:pass error:&e])
                    fprintf(stderr, "retry %d failed: %s\n", i, e.localizedDescription.UTF8String);
            }
        });
    }
    printf("Interface %s is bridged to Wi-Fi. Press Ctrl-C to stop.\n", nif.ifname.UTF8String);
    uint64_t lastRx = 0, lastTx = 0;
    for (int t = 0; !gStop; t++) {
        [NSThread sleepForTimeInterval:1.0];
        if (t % 10 == 9 && verbose) {
            printf("rssi %d dBm, rx %llu (+%llu) tx %llu (+%llu) drop %llu mic %llu\n", sta.lastRssi,
                   sta.rxData, sta.rxData - lastRx, sta.txData, sta.txData - lastTx, sta.rxDropped, sta.micFailures);
            lastRx = sta.rxData; lastTx = sta.txData;
        }
    }
    printf("\nshutting down...\n");
    [sta disconnect];
    [nif destroy];
    return 0;
}

static void usage(void) {
    fprintf(stderr,
        "usage: rtl8821au [-v] <command> [args]\n"
        "  info                          chip and eFuse information\n"
        "  selftest                      run crypto self-tests\n"
        "  scan [-2]                     list networks (-2: 2.4 GHz only)\n"
        "  connect <ssid> [-p pass]      join, test DHCP over the link, leave\n"
        "  up <ssid> [-p pass]           join and bridge to macOS as feth8021 (needs sudo)\n"
        "  daemon                        background service for the menu bar app (root)\n"
        "  sniff [-t sec] [ch...]        bring-up test: count beacons\n"
        "passphrase can also come from $RTL_PSK or an interactive prompt\n");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL verbose = NO;
        int ai = 1;
        if (ai < argc && !strcmp(argv[ai], "-v")) { verbose = YES; ai++; }
        if (ai >= argc) { usage(); return 1; }
        const char *cmd = argv[ai++];

        if (!strcmp(cmd, "daemon")) { extern int rtl_daemon_main(void); return rtl_daemon_main(); }
        if (!strcmp(cmd, "remove-service")) return [RTLNetif removeServiceForInterface:@"feth8021"] ? 0 : 1;
        if (!strcmp(cmd, "selftest")) {
            int f = wifi_crypto_selftest();
            printf(f ? "%d self-test(s) FAILED\n" : "all self-tests passed\n", f);
            return f ? 1 : 0;
        }

        NSError *err = nil;
        RTLUSB *usb = [RTLUSB openFirstSupported:&err];
        if (!usb) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }
        RTLHal *hal = [[RTLHal alloc] initWithUSB:usb];
        hal.verbose = verbose;
        if (![hal readEfuse]) { fprintf(stderr, "failed to read eFuse\n"); return 1; }
        const u8 *m = hal.efuse->mac;
        printf("%s, RTL8821A %c-cut, MAC %02x:%02x:%02x:%02x:%02x:%02x\n",
               usb.productName.UTF8String, 'A' + hal.cut, m[0], m[1], m[2], m[3], m[4], m[5]);
        if (!strcmp(cmd, "info")) return 0;

        NSData *fw = rtl_load_firmware();
        if (!fw) return 1;
        if (![hal powerOnWithFirmware:fw]) { fprintf(stderr, "power on failed\n"); return 1; }

        int rc;
        if (!strcmp(cmd, "sniff")) rc = cmdSniff(hal, argc - ai, argv + ai);
        else if (!strcmp(cmd, "scan")) rc = cmdScan(hal, argc - ai, argv + ai);
        else if (!strcmp(cmd, "connect")) rc = cmdConnect(hal, argc - ai, argv + ai, verbose);
        else if (!strcmp(cmd, "up")) rc = cmdUp(hal, argc - ai, argv + ai, verbose);
        else { usage(); rc = 1; }
        [hal.usb stopRx];
        [hal powerOff];
        return rc;
    }
}
