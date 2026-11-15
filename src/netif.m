#import "netif.h"
#import <SystemConfiguration/SystemConfiguration.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if_dl.h>
#include <net/bpf.h>
#include <net/if.h>
#include <spawn.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int run(NSArray<NSString *> *argv) {
    const char **a = calloc(argv.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argv.count; i++) a[i] = argv[i].UTF8String;
    pid_t pid;
    int st = -1;
    if (posix_spawn(&pid, a[0], NULL, NULL, (char *const *)a, environ) == 0) waitpid(pid, &st, 0);
    free(a);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static inline bool maceq(const u8 *a, const u8 *b) { return !memcmp(a, b, 6); }

static u16 csum_add(u32 s, const u8 *p, size_t n) {
    for (size_t i = 0; i + 1 < n; i += 2) s += p[i] << 8 | p[i + 1];
    if (n & 1) s += p[n - 1] << 8;
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (u16)s;
}

static void translate(u8 *f, size_t len, const u8 *from, const u8 *to, bool dir_out) {
    if (len < 14) return;
    if (dir_out) { if (maceq(f + 6, from)) memcpy(f + 6, to, 6); }
    else         { if (maceq(f + 0, from)) memcpy(f + 0, to, 6); }
    u16 type = f[12] << 8 | f[13];
    u8 *p = f + 14;
    size_t pl = len - 14;

    if (type == 0x0806 && pl >= 28) {
        if (maceq(p + 8, from)) memcpy(p + 8, to, 6);
        if (maceq(p + 18, from)) memcpy(p + 18, to, 6);
    } else if (type == 0x0800 && pl >= 20) {
        size_t ihl = (p[0] & 0xf) * 4;
        if (p[9] != 17 || pl < ihl + 8 + 236) return;
        u8 *udp = p + ihl;
        u16 sp = udp[0] << 8 | udp[1], dp = udp[2] << 8 | udp[3];
        if (!((sp == 68 && dp == 67) || (sp == 67 && dp == 68))) return;
        u8 *chaddr = udp + 8 + 28;
        if (maceq(chaddr, from)) {
            memcpy(chaddr, to, 6);
            udp[6] = udp[7] = 0;
        }
    } else if (type == 0x86dd && pl >= 48) {
        if (p[6] != 58) return;
        u16 plen = p[4] << 8 | p[5];
        if (40 + (size_t)plen > pl) return;
        u8 *icmp = p + 40;
        size_t off;
        switch (icmp[0]) {
        case 133: off = 8; break;
        case 134: off = 16; break;
        case 135: case 136: off = 24; break;
        case 137: off = 40; break;
        default: return;
        }
        bool changed = false;
        for (size_t o = off; o + 8 <= plen && icmp[o + 1]; o += icmp[o + 1] * 8)
            if ((icmp[o] == 1 || icmp[o] == 2) && maceq(icmp + o + 2, from)) {
                memcpy(icmp + o + 2, to, 6);
                changed = true;
            }
        if (!changed) return;
        icmp[2] = icmp[3] = 0;
        u8 ph[8] = {0, 0, plen >> 8, plen, 0, 0, 0, 58};
        u16 c = csum_add(0, p + 8, 32);
        c = csum_add(c, ph, 8);
        c = csum_add(c, icmp, plen);
        c = ~c;
        icmp[2] = c >> 8; icmp[3] = c;
    }
}

@implementation RTLNetif {
    u8 _hostMAC[6], _wifiMAC[6];
    NSString *_peer;
    int _bpf;
    size_t _blen;
    volatile BOOL _running;
    dispatch_semaphore_t _readerDone;
}

- (instancetype)initWithMAC:(const u8 *)mac error:(NSError **)err {
    if (!(self = [super init])) return nil;
    if (geteuid() != 0) {
        if (err) *err = [NSError errorWithDomain:@"rtl8821au" code:20
                            userInfo:@{NSLocalizedDescriptionKey: @"creating a network interface needs root (run with sudo)"}];
        return nil;
    }
    _ifname = @"feth8021";
    _peer = @"feth8022";
    run(@[@"/sbin/ifconfig", _ifname, @"destroy"]);
    run(@[@"/sbin/ifconfig", _peer, @"destroy"]);
    memcpy(_wifiMAC, mac, 6);
    if (run(@[@"/sbin/ifconfig", _ifname, @"create"]) || run(@[@"/sbin/ifconfig", _peer, @"create"]) ||
        run(@[@"/sbin/ifconfig", _ifname, @"peer", _peer]) ||
        run(@[@"/sbin/ifconfig", _ifname, @"mtu", @"1500"]) ||
        run(@[@"/sbin/ifconfig", _peer, @"up"])) {
        if (err) *err = [NSError errorWithDomain:@"rtl8821au" code:21
                            userInfo:@{NSLocalizedDescriptionKey: @"failed to create feth interface pair"}];
        return nil;
    }

    _bpf = -1;
    for (int i = 0; i < 256 && _bpf < 0; i++) {
        char dev[32];
        snprintf(dev, sizeof dev, "/dev/bpf%d", i);
        _bpf = open(dev, O_RDWR);
    }
    if (_bpf < 0) {
        if (err) *err = [NSError errorWithDomain:@"rtl8821au" code:22
                            userInfo:@{NSLocalizedDescriptionKey: @"no free /dev/bpf device"}];
        return nil;
    }
    u_int blen = 65536, one = 1, zero = 0;
    ioctl(_bpf, BIOCSBLEN, &blen);
    struct ifreq ifr = {0};
    strlcpy(ifr.ifr_name, _peer.UTF8String, sizeof ifr.ifr_name);
    if (ioctl(_bpf, BIOCSETIF, &ifr) < 0 || ioctl(_bpf, BIOCIMMEDIATE, &one) < 0 ||
        ioctl(_bpf, BIOCSHDRCMPLT, &one) < 0 || ioctl(_bpf, BIOCSSEESENT, &zero) < 0) {
        if (err) *err = [NSError errorWithDomain:@"rtl8821au" code:23
                            userInfo:@{NSLocalizedDescriptionKey: @"BPF setup failed"}];
        return nil;
    }
    ioctl(_bpf, BIOCPROMISC, NULL);
    struct timeval tv = { .tv_sec = 0, .tv_usec = 250000 };
    ioctl(_bpf, BIOCSRTIMEOUT, &tv);
    ioctl(_bpf, BIOCGBLEN, &blen);
    _blen = blen;
    [self readHostMAC];
    run(@[@"/sbin/ifconfig", _ifname, @"down"]);
    [RTLNetif installServiceForInterface:_ifname];
    return self;
}

- (void)readHostMAC {
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa)) return;
    for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_LINK || strcmp(i->ifa_name, _ifname.UTF8String)) continue;
        struct sockaddr_dl *dl = (struct sockaddr_dl *)i->ifa_addr;
        if (dl->sdl_alen == 6) memcpy(_hostMAC, LLADDR(dl), 6);
    }
    freeifaddrs(ifa);
}

- (void)start {
    _running = YES;
    _readerDone = dispatch_semaphore_create(0);
    [NSThread detachNewThreadWithBlock:^{
        u8 *buf = malloc(self->_blen);
        while (self->_running) {
            ssize_t n = read(self->_bpf, buf, self->_blen);
            if (n <= 0) continue;
            for (u8 *p = buf; p < buf + n;) {
                struct bpf_hdr *h = (struct bpf_hdr *)p;
                if (self.onFrame && h->bh_caplen == h->bh_datalen && h->bh_caplen >= 14) {
                    u8 *fr = p + h->bh_hdrlen;
                    if (!(fr[6] & 1) && !maceq(fr + 6, self->_wifiMAC))
                        memcpy(self->_hostMAC, fr + 6, 6);
                    translate(fr, h->bh_caplen, self->_hostMAC, self->_wifiMAC, true);
                    self.onFrame(fr, h->bh_caplen);
                }
                p += BPF_WORDALIGN(h->bh_hdrlen + h->bh_caplen);
            }
        }
        free(buf);
        dispatch_semaphore_signal(self->_readerDone);
    }];
}

- (BOOL)inject:(const u8 *)frame len:(size_t)len {
    if (len > 9000) return NO;
    u8 buf[9000];
    memcpy(buf, frame, len);
    translate(buf, len, _wifiMAC, _hostMAC, false);
    return write(_bpf, buf, len) == (ssize_t)len;
}

- (void)setLinkUp:(BOOL)up {
    NSLog(@"link %@ on %@", up ? @"up" : @"down", _ifname);
    run(@[@"/sbin/ifconfig", _ifname, up ? @"up" : @"down"]);
}

#define SVC_NAME @"RTL Wi-Fi"

+ (nullable NSString *)findService:(SCPreferencesRef)p ifname:(NSString *)ifname {
    NSDictionary *services = (__bridge NSDictionary *)SCPreferencesGetValue(p, kSCPrefNetworkServices);
    for (NSString *k in services)
        if ([services[k][@"Interface"][@"DeviceName"] isEqual:ifname]) return k;
    return nil;
}

+ (BOOL)installServiceForInterface:(NSString *)ifname {
    SCPreferencesRef p = SCPreferencesCreate(NULL, CFSTR("rtl8821au"), NULL);
    if (!p || !SCPreferencesLock(p, true)) { if (p) CFRelease(p); return NO; }
    NSString *sid = [self findService:p ifname:ifname];
    BOOL changed = NO;
    if (!sid) {
        sid = [NSUUID UUID].UUIDString;
        NSDictionary *svc = @{
            @"UserDefinedName": SVC_NAME,
            @"Interface": @{@"DeviceName": ifname, @"Hardware": @"Ethernet", @"Type": @"Ethernet",
                            @"UserDefinedName": SVC_NAME},
            @"IPv4": @{@"ConfigMethod": @"DHCP"},
            @"IPv6": @{@"ConfigMethod": @"Automatic"},
            @"DNS": @{},
            @"Proxies": @{@"ExceptionsList": @[@"*.local", @"169.254/16"], @"FTPPassive": @1},
        };
        SCPreferencesPathSetValue(p, (__bridge CFStringRef)[@"/NetworkServices/" stringByAppendingString:sid],
                                  (__bridge CFDictionaryRef)svc);
        changed = YES;
    }
    NSString *set = (__bridge NSString *)SCPreferencesGetValue(p, kSCPrefCurrentSet);
    if (set) {
        NSString *link = [NSString stringWithFormat:@"%@/Network/Service/%@", set, sid];
        if (!SCPreferencesPathGetValue(p, (__bridge CFStringRef)link)) {
            SCPreferencesPathSetLink(p, (__bridge CFStringRef)link,
                                     (__bridge CFStringRef)[@"/NetworkServices/" stringByAppendingString:sid]);
            changed = YES;
        }
        NSString *gpath = [set stringByAppendingString:@"/Network/Global/IPv4"];
        NSMutableDictionary *g = [(__bridge NSDictionary *)SCPreferencesPathGetValue(p, (__bridge CFStringRef)gpath) mutableCopy]
                                 ?: [NSMutableDictionary dictionary];
        NSMutableArray *order = [g[@"ServiceOrder"] mutableCopy] ?: [NSMutableArray array];
        if (![order containsObject:sid]) {
            [order addObject:sid];
            g[@"ServiceOrder"] = order;
            SCPreferencesPathSetValue(p, (__bridge CFStringRef)gpath, (__bridge CFDictionaryRef)g);
            changed = YES;
        }
    }
    BOOL ok = YES;
    if (changed) {
        ok = SCPreferencesCommitChanges(p) && SCPreferencesApplyChanges(p);
        NSLog(@"network service \"%@\" for %@ %@", SVC_NAME, ifname, ok ? @"installed" : @"FAILED to install");
    }
    SCPreferencesUnlock(p);
    CFRelease(p);
    return ok;
}

+ (BOOL)removeServiceForInterface:(NSString *)ifname {
    SCPreferencesRef p = SCPreferencesCreate(NULL, CFSTR("rtl8821au"), NULL);
    if (!p || !SCPreferencesLock(p, true)) { if (p) CFRelease(p); return NO; }
    NSString *sid;
    BOOL removed = NO;
    while ((sid = [self findService:p ifname:ifname])) {
        NSDictionary *sets = (__bridge NSDictionary *)SCPreferencesGetValue(p, kSCPrefSets);
        for (NSString *setId in sets) {
            NSString *set = [@"/Sets/" stringByAppendingString:setId];
            SCPreferencesPathRemoveValue(p, (__bridge CFStringRef)[NSString stringWithFormat:@"%@/Network/Service/%@", set, sid]);
            NSString *gpath = [set stringByAppendingString:@"/Network/Global/IPv4"];
            NSMutableDictionary *g = [(__bridge NSDictionary *)SCPreferencesPathGetValue(p, (__bridge CFStringRef)gpath) mutableCopy];
            NSMutableArray *order = [g[@"ServiceOrder"] mutableCopy];
            if ([order containsObject:sid]) {
                [order removeObject:sid];
                g[@"ServiceOrder"] = order;
                SCPreferencesPathSetValue(p, (__bridge CFStringRef)gpath, (__bridge CFDictionaryRef)g);
            }
        }
        SCPreferencesPathRemoveValue(p, (__bridge CFStringRef)[@"/NetworkServices/" stringByAppendingString:sid]);
        removed = YES;
    }
    BOOL ok = !removed || (SCPreferencesCommitChanges(p) && SCPreferencesApplyChanges(p));
    SCPreferencesUnlock(p);
    CFRelease(p);
    return ok;
}

- (void)setMAC:(const u8 *)mac { memcpy(_wifiMAC, mac, 6); }

- (void)destroy {
    if (_running) {
        _running = NO;
        dispatch_semaphore_wait(_readerDone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
    if (_bpf >= 0) { close(_bpf); _bpf = -1; }
    run(@[@"/sbin/ifconfig", _ifname, @"destroy"]);
    run(@[@"/sbin/ifconfig", _peer, @"destroy"]);
}
@end
