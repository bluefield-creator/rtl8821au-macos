#import <Cocoa/Cocoa.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define SOCK_PATH "/var/run/rtl8821au.sock"

static NSDictionary *daemonRequest(NSDictionary *req, double timeout) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strlcpy(a.sun_path, SOCK_PATH, sizeof a.sun_path);
    if (connect(fd, (struct sockaddr *)&a, sizeof a)) { close(fd); return nil; }
    struct timeval tv = {(time_t)timeout, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    NSMutableData *out = [[NSJSONSerialization dataWithJSONObject:req options:0 error:nil] mutableCopy];
    [out appendBytes:"\n" length:1];
    write(fd, out.bytes, out.length);
    NSMutableData *in = [NSMutableData data];
    char buf[8192];
    ssize_t n;
    while ((n = read(fd, buf, sizeof buf)) > 0) [in appendBytes:buf length:n];
    close(fd);
    id r = [NSJSONSerialization JSONObjectWithData:in options:0 error:nil];
    return [r isKindOfClass:[NSDictionary class]] ? r : nil;
}

static double signalLevel(int rssi) {
    if (rssi >= -55) return 1.0;
    if (rssi >= -67) return 0.66;
    if (rssi >= -78) return 0.33;
    return 0.1;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation AppDelegate {
    NSStatusItem *_item;
    NSMenu *_menu;
    NSDictionary *_status;
    NSArray<NSDictionary *> *_networks;
    BOOL _scanning, _connecting;
    NSString *_connectingTo;
    dispatch_queue_t _q;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    _q = dispatch_queue_create("rtlwifi.client", DISPATCH_QUEUE_CONCURRENT);
    _item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    _menu = [[NSMenu alloc] init];
    _menu.delegate = self;
    _menu.autoenablesItems = NO;
    _item.menu = _menu;
    [self updateIcon];
    [self refresh];
    [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *t) { [self refresh]; }];
}

- (void)refresh {
    dispatch_async(_q, ^{
        NSDictionary *s = daemonRequest(@{@"cmd": @"status"}, 3);
        dispatch_async(dispatch_get_main_queue(), ^{ self->_status = s; [self updateIcon]; });
    });
}

- (void)fetchNetworks:(BOOL)cached {
    if (_scanning) return;
    _scanning = YES;
    dispatch_async(_q, ^{
        NSDictionary *r = daemonRequest(@{@"cmd": @"scan", @"cached": @(cached)}, 20);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_scanning = NO;
            if ([r[@"ok"] boolValue]) self->_networks = r[@"networks"];
            [self rebuildMenu];
        });
    });
}

- (NSString *)state { return _status[@"state"]; }

- (void)updateIcon {
    NSImage *img;
    NSString *desc;
    if (!_status) {
        img = [NSImage imageWithSystemSymbolName:@"wifi.exclamationmark" accessibilityDescription:@"Driver not running"];
        desc = @"Wi-Fi driver not running";
    } else if (![_status[@"adapter"] boolValue] || ![_status[@"enabled"] boolValue]) {
        img = [NSImage imageWithSystemSymbolName:@"wifi.slash" accessibilityDescription:@"Wi-Fi off"];
        desc = [_status[@"adapter"] boolValue] ? @"Wi-Fi off" : @"Wi-Fi adapter not connected";
    } else if ([self.state isEqual:@"connected"]) {
        img = [NSImage imageWithSystemSymbolName:@"wifi" variableValue:signalLevel([_status[@"rssi"] intValue])
                        accessibilityDescription:@"Wi-Fi connected"];
        desc = [NSString stringWithFormat:@"Connected to %@", _status[@"ssid"]];
    } else {
        img = [NSImage imageWithSystemSymbolName:@"wifi" variableValue:0 accessibilityDescription:@"Wi-Fi not connected"];
        desc = _status[@"activity"];
    }
    img.template = YES;
    _item.button.image = img;
    _item.button.toolTip = desc;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self rebuildMenu];
    if ([_status[@"adapter"] boolValue] && [_status[@"enabled"] boolValue])
        [self fetchNetworks:YES];
    [self refresh];
}

- (NSMenuItem *)addText:(NSString *)t bold:(BOOL)bold {
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:t action:nil keyEquivalent:@""];
    NSFont *f = bold ? [NSFont boldSystemFontOfSize:13] : [NSFont menuFontOfSize:12];
    NSColor *c = bold ? NSColor.labelColor : NSColor.secondaryLabelColor;
    i.attributedTitle = [[NSAttributedString alloc] initWithString:t attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: c}];
    i.enabled = NO;
    [_menu addItem:i];
    return i;
}

- (NSMenuItem *)addAction:(NSString *)t sel:(SEL)sel {
    NSMenuItem *i = [_menu addItemWithTitle:t action:sel keyEquivalent:@""];
    i.target = self;
    return i;
}

- (void)rebuildMenu {
    [_menu removeAllItems];
    NSDictionary *s = _status;
    if (!s) {
        [self addText:@"Wi-Fi (RTL8821AU)" bold:YES];
        [self addText:@"The driver service isn't running." bold:NO];
        [self addText:@"Run install.sh to set it up." bold:NO];
        [_menu addItem:[NSMenuItem separatorItem]];
        [self addAction:@"Quit" sel:@selector(quit:)];
        return;
    }
    BOOL adapter = [s[@"adapter"] boolValue], enabled = [s[@"enabled"] boolValue];
    BOOL connected = [s[@"state"] isEqual:@"connected"];

    [self addText:@"Wi-Fi (RTL8821AU)" bold:YES];
    NSMenuItem *toggle = [self addAction:enabled ? @"Turn Wi-Fi Off" : @"Turn Wi-Fi On" sel:@selector(toggleEnabled:)];
    toggle.enabled = adapter;
    if (!adapter) [self addText:@"Adapter not plugged in" bold:NO];
    else if (_connecting) [self addText:[NSString stringWithFormat:@"Connecting to %@…", _connectingTo] bold:NO];
    else if (connected) {
        [self addText:[NSString stringWithFormat:@"%@ · %@ dBm · ch %@", s[@"ssid"], s[@"rssi"], s[@"channel"]] bold:NO];
        [self addText:[NSString stringWithFormat:@"IP %@ on %@", s[@"ip"] ?: @"(waiting for DHCP)", s[@"interface"]] bold:NO];
    } else if (enabled) [self addText:s[@"activity"] ?: @"Not connected" bold:NO];
    if (s[@"error"] && !connected && !_connecting) [self addText:s[@"error"] bold:NO];

    if (adapter && enabled) {
        [_menu addItem:[NSMenuItem separatorItem]];
        [self addText:@"Networks" bold:YES];
        if (!_networks.count) [self addText:_scanning ? @"Scanning…" : @"No networks found" bold:NO];
        NSSet *known = [NSSet setWithArray:s[@"known"] ?: @[]];
        NSArray *sorted = [_networks sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL ka = [known containsObject:a[@"ssid"]], kb = [known containsObject:b[@"ssid"]];
            if (ka != kb) return ka ? NSOrderedAscending : NSOrderedDescending;
            return [b[@"rssi"] compare:a[@"rssi"]];
        }];
        for (NSDictionary *n in sorted) {
            NSMenuItem *i = [self addAction:n[@"ssid"] sel:@selector(pickNetwork:)];
            i.representedObject = n;
            i.image = [NSImage imageWithSystemSymbolName:@"wifi" variableValue:signalLevel([n[@"rssi"] intValue])
                                accessibilityDescription:nil];
            if (connected && [n[@"ssid"] isEqual:s[@"ssid"]]) i.state = NSControlStateValueOn;
            NSMutableArray *bits = [NSMutableArray array];
            if ([n[@"secure"] boolValue]) [bits addObject:@"🔒"];
            [bits addObject:[n[@"channel"] intValue] > 14 ? @"5 GHz" : @"2.4 GHz"];
            if (![n[@"supported"] boolValue]) { [bits addObject:n[@"security"]]; i.enabled = NO; }
            i.toolTip = [NSString stringWithFormat:@"%@, %@ dBm, channel %@", n[@"security"], n[@"rssi"], n[@"channel"]];
            NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:n[@"ssid"]];
            [t appendAttributedString:[[NSAttributedString alloc]
                initWithString:[@"   " stringByAppendingString:[bits componentsJoinedByString:@" · "]]
                    attributes:@{NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
                                 NSFontAttributeName: [NSFont menuFontOfSize:11]}]];
            i.attributedTitle = t;
        }
        [_menu addItem:[NSMenuItem separatorItem]];
        [self addAction:_scanning ? @"Scanning…" : @"Scan for Networks" sel:@selector(rescan:)].enabled = !_scanning;
        if (connected) {
            [self addAction:@"Disconnect" sel:@selector(disconnect:)];
            NSMenuItem *f = [self addAction:[NSString stringWithFormat:@"Forget “%@”", s[@"ssid"]] sel:@selector(forget:)];
            f.representedObject = s[@"ssid"];
        }
    }
    [_menu addItem:[NSMenuItem separatorItem]];
    [self addAction:@"Quit Menu" sel:@selector(quit:)];
}

- (void)toggleEnabled:(id)sender {
    BOOL on = ![_status[@"enabled"] boolValue];
    dispatch_async(_q, ^{ daemonRequest(@{@"cmd": @"enable", @"on": @(on)}, 10); [self refresh]; });
}

- (void)rescan:(id)sender { [self fetchNetworks:NO]; }

- (void)disconnect:(id)sender {
    dispatch_async(_q, ^{ daemonRequest(@{@"cmd": @"disconnect"}, 10); [self refresh]; });
}

- (void)forget:(NSMenuItem *)sender {
    NSString *ssid = sender.representedObject;
    dispatch_async(_q, ^{
        daemonRequest(@{@"cmd": @"forget", @"ssid": ssid}, 5);
        daemonRequest(@{@"cmd": @"disconnect"}, 10);
        [self refresh];
    });
}

- (void)pickNetwork:(NSMenuItem *)sender {
    NSDictionary *n = sender.representedObject;
    NSString *ssid = n[@"ssid"];
    NSArray *known = _status[@"known"] ?: @[];
    if ([n[@"secure"] boolValue] && ![known containsObject:ssid]) {
        [self askPasswordFor:ssid];
        return;
    }
    [self connect:ssid password:nil remember:YES];
}

- (void)askPasswordFor:(NSString *)ssid {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"The Wi-Fi network “%@” requires a WPA2 password.", ssid];
    a.icon = [NSImage imageWithSystemSymbolName:@"wifi" accessibilityDescription:nil];
    [a addButtonWithTitle:@"Join"];
    [a addButtonWithTitle:@"Cancel"];
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 54)];
    NSSecureTextField *pw = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 28, 260, 24)];
    pw.placeholderString = @"Password";
    NSButton *remember = [NSButton checkboxWithTitle:@"Remember this network" target:nil action:nil];
    remember.frame = NSMakeRect(0, 0, 260, 20);
    remember.state = NSControlStateValueOn;
    [v addSubview:pw];
    [v addSubview:remember];
    a.accessoryView = v;
    [a.window setInitialFirstResponder:pw];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    [self connect:ssid password:pw.stringValue remember:remember.state == NSControlStateValueOn];
}

- (void)connect:(NSString *)ssid password:(NSString *)pw remember:(BOOL)remember {
    _connecting = YES;
    _connectingTo = ssid;
    NSMutableDictionary *req = [@{@"cmd": @"connect", @"ssid": ssid, @"remember": @(remember)} mutableCopy];
    if (pw.length) req[@"password"] = pw;
    dispatch_async(_q, ^{
        NSDictionary *r = daemonRequest(req, 30);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_connecting = NO;
            [self refresh];
            if (![r[@"ok"] boolValue]) {
                [NSApp activateIgnoringOtherApps:YES];
                NSAlert *a = [[NSAlert alloc] init];
                a.messageText = [NSString stringWithFormat:@"Couldn't join “%@”", ssid];
                a.informativeText = r[@"error"] ?: @"The driver service didn't respond.";
                [a runModal];
            }
        });
    });
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
