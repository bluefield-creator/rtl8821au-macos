#import <Foundation/Foundation.h>
#import "rtl_usb.h"
#import "rtl_hal.h"
#import "wifi_sta.h"
#import "netif.h"
#include <arpa/inet.h>
#include <grp.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define SOCK_PATH  "/var/run/rtl8821au.sock"
#define STATE_DIR  @"/Library/Application Support/rtl8821au"
#define LOGD(...) do { NSLog(@__VA_ARGS__); } while (0)

NSData *rtl_load_firmware(void);

@interface RTLDaemon : NSObject
@end

@implementation RTLDaemon {
    dispatch_queue_t _ctl;
    RTLUSB *_usb;
    RTLHal *_hal;
    RTLStation *_sta;
    RTLNetif *_nif;
    NSMutableDictionary *_known;
    NSMutableDictionary *_settings;
    NSArray<RTLBss *> *_lastScan;
    NSDate *_lastScanTime;
    NSString *_status;
    NSString *_lastError;
    BOOL _userDisconnected, _busy;
    NSDate *_nextAutojoin;
}

- (NSString *)path:(NSString *)name { return [STATE_DIR stringByAppendingPathComponent:name]; }

- (void)load {
    [[NSFileManager defaultManager] createDirectoryAtPath:STATE_DIR withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0700} error:nil];
    _known = [[NSDictionary dictionaryWithContentsOfFile:[self path:@"networks.plist"]] mutableCopy]
             ?: [NSMutableDictionary dictionary];
    _settings = [[NSDictionary dictionaryWithContentsOfFile:[self path:@"settings.plist"]] mutableCopy]
                ?: [@{@"enabled": @YES} mutableCopy];
}

- (void)save {
    NSString *n = [self path:@"networks.plist"], *s = [self path:@"settings.plist"];
    [_known writeToFile:n atomically:YES];
    [_settings writeToFile:s atomically:YES];
    chmod(n.fileSystemRepresentation, 0600);
    chmod(s.fileSystemRepresentation, 0600);
}

- (BOOL)enabled { return [_settings[@"enabled"] boolValue]; }

- (void)run {
    _ctl = dispatch_queue_create("rtl.daemon", DISPATCH_QUEUE_SERIAL);
    [self load];
    _status = @"Waiting for adapter";

    NSError *err = nil;
    u8 zero[6] = {0x02, 0, 0, 0, 0, 1};
    _nif = [[RTLNetif alloc] initWithMAC:zero error:&err];
    if (!_nif) { LOGD("netif: %@", err.localizedDescription); exit(1); }
    __weak RTLDaemon *weak = self;
    _nif.onFrame = ^(const u8 *f, size_t len) {
        RTLDaemon *d = weak;
        RTLStation *sta = d ? d->_sta : nil;
        [sta sendEthernet:f len:len];
    };
    [_nif start];

    [self startSocket];

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _ctl);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(t, ^{ [weak housekeeping]; });
    dispatch_resume(t);

    int sigs[2] = {SIGINT, SIGTERM};
    for (int i = 0; i < 2; i++) {
        int sig = sigs[i];
        signal(sig, SIG_IGN);
        dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, _ctl);
        dispatch_source_set_event_handler(s, ^{ [weak shutdown]; });
        dispatch_resume(s);
        (void)CFBridgingRetain(s);
    }
    (void)CFBridgingRetain(t);
    dispatch_main();
}

- (void)shutdown {
    LOGD("shutting down");
    [_sta disconnect];
    [self dropDevice];
    [_nif destroy];
    unlink(SOCK_PATH);
    exit(0);
}

- (void)housekeeping {
    if (_busy) return;
    if (_usb.gone) { LOGD("adapter unplugged"); [self dropDevice]; }
    if (!_usb) { [self tryOpenDevice]; return; }
    if (![self enabled] || _userDisconnected) return;
    if (_sta.state == RTLStaIdle && (!_nextAutojoin || [_nextAutojoin timeIntervalSinceNow] <= 0))
        [self autojoin];
}

- (void)tryOpenDevice {
    RTLUSB *usb = [RTLUSB openFirstSupported:nil];
    if (!usb) return;
    LOGD("adapter found: %@", usb.productName);
    _status = @"Starting adapter";
    RTLHal *hal = [[RTLHal alloc] initWithUSB:usb];
    NSData *fw = rtl_load_firmware();
    if (![hal readEfuse] || !fw || ![hal powerOnWithFirmware:fw]) {
        LOGD("adapter initialisation failed");
        _lastError = @"Adapter initialisation failed";
        [usb close];
        return;
    }
    @synchronized(self) { _usb = usb; _hal = hal; }
    __weak RTLDaemon *weak = self;
    usb.onRemoved = ^{ RTLDaemon *d = weak; if (d) dispatch_async(d->_ctl, ^{ [d housekeeping]; }); };

    [_nif setMAC:hal.efuse->mac];
    RTLStation *sta = [[RTLStation alloc] initWithHal:hal];
    @synchronized(self) { _sta = sta; }
    RTLNetif *nif = _nif;
    _sta.onEthernet = ^(const u8 *f, size_t len) { [nif inject:f len:len]; };
    _sta.onLinkChange = ^(BOOL up) {
        RTLDaemon *d = weak;
        if (!d) return;
        [nif setLinkUp:up];
        if (!up) dispatch_async(d->_ctl, ^{
            d->_status = @"Disconnected";
            d->_nextAutojoin = [NSDate dateWithTimeIntervalSinceNow:2];
        });
    };
    _status = @"Disconnected";
    _nextAutojoin = nil;
}

- (void)dropDevice {
    if (!_usb) return;
    [_nif setLinkUp:NO];
    [_sta shutdown];
    if (!_usb.gone) [_hal powerOff];
    [_usb close];
    @synchronized(self) { _sta = nil; _hal = nil; _usb = nil; }
    _status = @"Waiting for adapter";
}

- (NSArray<RTLBss *> *)scan {
    if (!_sta) return @[];
    _status = _sta.state == RTLStaConnected ? _status : @"Scanning";
    _lastScan = [_sta scanForSSID:nil dwell:0.12 include5GHz:YES];
    _lastScanTime = [NSDate date];
    if (_sta.state != RTLStaConnected) _status = @"Disconnected";
    return _lastScan;
}

- (BOOL)join:(RTLBss *)b password:(NSString *)pw error:(NSError **)err {
    _status = [NSString stringWithFormat:@"Connecting to %@", b.ssid];
    BOOL ok = [_sta joinBss:b passphrase:pw error:err];
    _status = ok ? @"Connected" : @"Disconnected";
    return ok;
}

- (void)autojoin {
    if (!_known.count) { _nextAutojoin = [NSDate dateWithTimeIntervalSinceNow:30]; [self scan]; return; }
    NSArray<RTLBss *> *res = [self scan];
    for (RTLBss *b in res) {
        NSDictionary *k = _known[b.ssid];
        if (!k || b.security == RTLSecUnsupported) continue;
        LOGD("auto-joining %@ (%d dBm)", b.ssid, b.rssi);
        NSError *e = nil;
        if ([self join:b password:k[@"password"] error:&e]) {
            _lastError = nil;
            NSMutableDictionary *m = [k mutableCopy];
            m[@"lastUsed"] = [NSDate date];
            _known[b.ssid] = m;
            [self save];
            return;
        }
        _lastError = e.localizedDescription;
        LOGD("auto-join failed: %@", e.localizedDescription);
    }
    _nextAutojoin = [NSDate dateWithTimeIntervalSinceNow:15];
}

- (NSString *)ipv4 {
    struct ifaddrs *ifa = NULL, *i;
    NSString *ip = nil;
    if (getifaddrs(&ifa) == 0) {
        for (i = ifa; i; i = i->ifa_next) {
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
            if (strcmp(i->ifa_name, _nif.ifname.UTF8String)) continue;
            char buf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, sizeof buf);
            ip = @(buf);
        }
        freeifaddrs(ifa);
    }
    return ip;
}

- (NSDictionary *)bssDict:(RTLBss *)b {
    return @{@"ssid": b.ssid ?: @"", @"bssid": b.bssidString, @"channel": @(b.channel), @"rssi": @(b.rssi),
             @"security": b.securityDesc ?: @"", @"secure": @(b.security != RTLSecOpen),
             @"supported": @(b.security != RTLSecUnsupported), @"known": @(_known[b.ssid] != nil)};
}

- (NSDictionary *)statusDict {
    @synchronized(self) { return [self statusDictLocked]; }
}

- (NSDictionary *)statusDictLocked {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"adapter"] = @(_usb != nil);
    d[@"enabled"] = @([self enabled]);
    d[@"interface"] = _nif.ifname;
    d[@"activity"] = _status ?: @"";
    if (_lastError) d[@"error"] = _lastError;
    if (_usb) d[@"adapterName"] = _usb.productName;
    BOOL connected = _sta.state == RTLStaConnected;
    d[@"state"] = connected ? @"connected" : (_sta.state == RTLStaIdle ? @"disconnected" : @"connecting");
    if (connected) {
        RTLBss *b = _sta.bss;
        d[@"ssid"] = b.ssid; d[@"bssid"] = b.bssidString; d[@"channel"] = @(b.channel);
        d[@"rssi"] = @(_sta.lastRssi);
        d[@"security"] = b.securityDesc;
        d[@"rx"] = @(_sta.rxData); d[@"tx"] = @(_sta.txData);
        NSString *ip = [self ipv4];
        if (ip) d[@"ip"] = ip;
    }
    d[@"known"] = _known.allKeys;
    return d;
}

- (NSDictionary *)handle:(NSDictionary *)req {
    NSString *cmd = req[@"cmd"];
    if ([cmd isEqual:@"status"]) return [self statusDict];
    if ([cmd isEqual:@"enable"]) {
        BOOL on = [req[@"on"] boolValue];
        _settings[@"enabled"] = @(on);
        [self save];
        if (!on) { [_sta disconnect]; _status = @"Wi-Fi off"; }
        else { _userDisconnected = NO; _nextAutojoin = nil; _status = @"Disconnected"; }
        return @{@"ok": @YES};
    }
    if ([cmd isEqual:@"forget"]) {
        NSString *ssid = req[@"ssid"];
        if (ssid) [_known removeObjectForKey:ssid];
        [self save];
        return @{@"ok": @YES};
    }
    if (!_sta) return @{@"ok": @NO, @"error": @"Wi-Fi adapter not connected"};
    if ([cmd isEqual:@"scan"]) {
        NSArray *res = _lastScan;
        BOOL fresh = _lastScanTime && -[_lastScanTime timeIntervalSinceNow] < 60;
        if (!([req[@"cached"] boolValue] && fresh && res)) res = [self scan];
        NSMutableArray *out = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (RTLBss *b in res) {
            if (!b.ssid.length || [seen containsObject:b.ssid]) continue;
            [seen addObject:b.ssid];
            [out addObject:[self bssDict:b]];
        }
        return @{@"ok": @YES, @"networks": out};
    }
    if ([cmd isEqual:@"disconnect"]) {
        _userDisconnected = YES;
        [_sta disconnect];
        _status = @"Disconnected";
        return @{@"ok": @YES};
    }
    if ([cmd isEqual:@"connect"]) {
        NSString *ssid = req[@"ssid"], *pw = req[@"password"];
        if (!ssid.length) return @{@"ok": @NO, @"error": @"missing ssid"};
        if (!pw.length) pw = _known[ssid][@"password"];
        if (![self enabled]) { _settings[@"enabled"] = @YES; [self save]; }
        _userDisconnected = NO;
        RTLBss *pick = nil;
        for (int pass = 0; pass < 2 && !pick; pass++) {
            NSArray *res = (pass == 0 && _lastScanTime && -[_lastScanTime timeIntervalSinceNow] < 20) ? _lastScan : [self scan];
            for (RTLBss *b in res) if ([b.ssid isEqualToString:ssid]) { pick = b; break; }
        }
        if (!pick) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"“%@” was not found", ssid]};
        NSError *e = nil;
        if (![self join:pick password:pw error:&e]) {
            _lastError = e.localizedDescription;
            _nextAutojoin = [NSDate dateWithTimeIntervalSinceNow:30];
            return @{@"ok": @NO, @"error": e.localizedDescription ?: @"failed"};
        }
        _lastError = nil;
        if ([req[@"remember"] boolValue] || _known[ssid]) {
            NSMutableDictionary *k = [NSMutableDictionary dictionary];
            if (pw) k[@"password"] = pw;
            k[@"lastUsed"] = [NSDate date];
            _known[ssid] = k;
            [self save];
        }
        return @{@"ok": @YES};
    }
    return @{@"ok": @NO, @"error": @"unknown command"};
}

- (void)startSocket {
    unlink(SOCK_PATH);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strlcpy(a.sun_path, SOCK_PATH, sizeof a.sun_path);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 8)) { LOGD("socket: %s", strerror(errno)); exit(1); }
    struct group *g = getgrnam("admin");
    chown(SOCK_PATH, 0, g ? g->gr_gid : 80);
    chmod(SOCK_PATH, 0660);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0,
                                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    __weak RTLDaemon *weak = self;
    dispatch_source_set_event_handler(src, ^{
        int c = accept(fd, NULL, NULL);
        if (c < 0) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [weak serveClient:c]; });
    });
    dispatch_resume(src);
    (void)CFBridgingRetain(src);
}

- (void)serveClient:(int)c {
    struct timeval tv = {5, 0};
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    NSMutableData *in = [NSMutableData data];
    char buf[4096];
    ssize_t n;
    while ((n = read(c, buf, sizeof buf)) > 0) {
        [in appendBytes:buf length:n];
        if (memchr(buf, '\n', n) || in.length > 65536) break;
    }
    NSDictionary *req = [NSJSONSerialization JSONObjectWithData:in options:0 error:nil];
    __block NSDictionary *resp;
    if (![req isKindOfClass:[NSDictionary class]]) resp = @{@"ok": @NO, @"error": @"bad request"};
    else if ([req[@"cmd"] isEqual:@"status"]) {
        resp = [self statusDict];
    } else {
        dispatch_sync(_ctl, ^{ self->_busy = YES; resp = [self handle:req]; self->_busy = NO; });
    }
    NSMutableData *out = [[NSJSONSerialization dataWithJSONObject:resp options:0 error:nil] mutableCopy];
    [out appendBytes:"\n" length:1];
    write(c, out.bytes, out.length);
    close(c);
}
@end

int rtl_daemon_main(void) {
    if (geteuid() != 0) { fprintf(stderr, "daemon must run as root\n"); return 1; }
    [[RTLDaemon new] run];
    return 0;
}
