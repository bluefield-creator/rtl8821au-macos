#import "rtl_usb.h"
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>

#define RTW_USB_CMD_READ  0xC0
#define RTW_USB_CMD_WRITE 0x40
#define RTW_USB_CMD_REQ   0x05
#define RX_BUF_SIZE       32768
#define RX_INFLIGHT       4

static const struct { uint16_t vid, pid; const char *name; } kSupported[] = {
    {0x2357, 0x0120, "TP-Link Archer T2U Plus"},
    {0x2357, 0x011E, "TP-Link Archer T2U Nano"},
    {0x2357, 0x011F, "TP-Link Archer T2U v3"},
    {0x0BDA, 0x0811, "Realtek RTL8811AU"},
    {0x0BDA, 0x0821, "Realtek RTL8821AU"},
    {0x0BDA, 0x0823, "Realtek RTL8821AU"},
    {0x0BDA, 0xA811, "Realtek RTL8811AU"},
    {0x7392, 0xA811, "Edimax EW-7811UTC"},
    {0x0E66, 0x0023, "Hawking HD65U"},
};

@implementation RTLUSB {
    IOUSBHostDevice *_dev;
    IOUSBHostInterface *_intf;
    IOUSBHostPipe *_in;
    NSMutableArray<IOUSBHostPipe *> *_out;
    dispatch_queue_t _q, _rxq;
    RTLRxHandler _rxHandler;
    volatile BOOL _rxRunning;
}

+ (instancetype)openFirstSupported:(NSError **)err {
    for (size_t i = 0; i < sizeof kSupported / sizeof *kSupported; i++) {
        CFMutableDictionaryRef m = [IOUSBHostDevice
            createMatchingDictionaryWithVendorID:@(kSupported[i].vid)
                                       productID:@(kSupported[i].pid)
                                       bcdDevice:nil deviceClass:nil deviceSubclass:nil
                                  deviceProtocol:nil speed:nil productIDArray:nil];
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
        if (!svc) continue;
        RTLUSB *u = [[RTLUSB alloc] initWithService:svc
                                                vid:kSupported[i].vid pid:kSupported[i].pid
                                               name:@(kSupported[i].name) error:err];
        IOObjectRelease(svc);
        return u;
    }
    if (err) *err = [NSError errorWithDomain:@"rtl8821au" code:1
                        userInfo:@{NSLocalizedDescriptionKey: @"no supported RTL8821AU dongle found"}];
    return nil;
}

- (instancetype)initWithService:(io_service_t)svc vid:(uint16_t)vid pid:(uint16_t)pid
                           name:(NSString *)name error:(NSError **)err {
    if (!(self = [super init])) return nil;
    _vendorID = vid; _productID = pid; _productName = name;
    _q = dispatch_queue_create("rtl.usb", DISPATCH_QUEUE_SERIAL);
    _rxq = dispatch_queue_create("rtl.rx", DISPATCH_QUEUE_SERIAL);

    __weak RTLUSB *weakSelf = self;
    _dev = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone
                                                queue:_q error:err
        interestHandler:^(IOUSBHostObject *obj, uint32_t type, void *arg) {
            if (type == kIOMessageServiceIsTerminated) [weakSelf markGone];
        }];
    if (!_dev) return nil;

    io_iterator_t it = IO_OBJECT_NULL;
    IORegistryEntryCreateIterator(svc, kIOServicePlane, kIORegistryIterateRecursively, &it);
    io_service_t child, intfSvc = IO_OBJECT_NULL;
    while ((child = IOIteratorNext(it))) {
        if (IOObjectConformsTo(child, "IOUSBHostInterface")) { intfSvc = child; break; }
        IOObjectRelease(child);
    }
    IOObjectRelease(it);
    if (!intfSvc) {
        if (err) *err = [NSError errorWithDomain:@"rtl8821au" code:2
                            userInfo:@{NSLocalizedDescriptionKey: @"USB interface not found"}];
        return nil;
    }
    _intf = [[IOUSBHostInterface alloc] initWithIOService:intfSvc options:IOUSBHostObjectInitOptionsNone
                                                    queue:_q error:err interestHandler:nil];
    IOObjectRelease(intfSvc);
    if (!_intf) return nil;

    _out = [NSMutableArray array];
    const IOUSBConfigurationDescriptor *cfg = _intf.configurationDescriptor;
    const IOUSBInterfaceDescriptor *idesc = _intf.interfaceDescriptor;
    const IOUSBEndpointDescriptor *ep = NULL;
    while ((ep = IOUSBGetNextEndpointDescriptor(cfg, idesc, (const IOUSBDescriptorHeader *)ep))) {
        uint8_t addr = ep->bEndpointAddress;
        uint8_t type = ep->bmAttributes & 0x3;
        if (type != kIOUSBEndpointTypeBulk) continue;
        IOUSBHostPipe *p = [_intf copyPipeWithAddress:addr error:err];
        if (!p) return nil;
        if (addr & 0x80) { if (!_in) _in = p; }
        else [_out addObject:p];
        if (ep->wMaxPacketSize == 512) _highSpeed = YES;
    }
    _bulkOutCount = (int)_out.count;
    if (!_in || _out.count == 0) {
        if (err) *err = [NSError errorWithDomain:@"rtl8821au" code:3
                            userInfo:@{NSLocalizedDescriptionKey: @"bulk endpoints not found"}];
        return nil;
    }
    return self;
}

- (void)markGone {
    if (_gone) return;
    _gone = YES;
    _rxRunning = NO;
    void (^cb)(void) = self.onRemoved;
    if (cb) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), cb);
}

- (void)close {
    [self stopRx];
    [_intf destroy]; _intf = nil;
    [_dev destroy]; _dev = nil;
}

- (void)dealloc { [self close]; }

- (BOOL)ctrl:(uint8_t)type addr:(u16)addr buf:(void *)buf len:(u16)len {
    if (_gone || !_dev) return NO;
    IOUSBDeviceRequest r = { .bmRequestType = type, .bRequest = RTW_USB_CMD_REQ,
                             .wValue = addr, .wIndex = 0, .wLength = len };
    NSMutableData *d = [NSMutableData dataWithBytes:buf length:len];
    NSUInteger done = 0;
    NSError *e = nil;
    for (int attempt = 0; attempt < 3; attempt++) {
        if ([_dev sendDeviceRequest:r data:d bytesTransferred:&done completionTimeout:1.0 error:&e]
            && done == len) {
            if (type & 0x80) memcpy(buf, d.bytes, len);
            return YES;
        }
    }
    if (_ctrlErrors++ < 8)
        fprintf(stderr, "usb: %s 0x%04x len %u failed: %s\n", (type & 0x80) ? "read" : "write",
                addr, len, e.localizedDescription.UTF8String ?: "short");
    return NO;
}

- (u8)rd8:(u16)a  { u8 v = 0;  [self ctrl:RTW_USB_CMD_READ addr:a buf:&v len:1]; return v; }
- (u16)rd16:(u16)a { u16 v = 0; [self ctrl:RTW_USB_CMD_READ addr:a buf:&v len:2]; return CFSwapInt16LittleToHost(v); }
- (u32)rd32:(u16)a { u32 v = 0; [self ctrl:RTW_USB_CMD_READ addr:a buf:&v len:4]; return CFSwapInt32LittleToHost(v); }
- (void)wr8:(u16)a val:(u8)v   { [self ctrl:RTW_USB_CMD_WRITE addr:a buf:&v len:1]; }
- (void)wr16:(u16)a val:(u16)v { v = CFSwapInt16HostToLittle(v); [self ctrl:RTW_USB_CMD_WRITE addr:a buf:&v len:2]; }
- (void)wr32:(u16)a val:(u32)v { v = CFSwapInt32HostToLittle(v); [self ctrl:RTW_USB_CMD_WRITE addr:a buf:&v len:4]; }
- (BOOL)writeBlock:(u16)a data:(const void *)d len:(u16)len {
    return [self ctrl:RTW_USB_CMD_WRITE addr:a buf:(void *)d len:len];
}

- (BOOL)bulkOut:(int)ep data:(NSData *)d {
    if (_gone) return NO;
    if (ep < 0 || ep >= (int)_out.count) return NO;
    NSMutableData *m = [d mutableCopy];
    NSUInteger done = 0;
    NSError *e = nil;
    BOOL ok = [_out[ep] sendIORequestWithData:m bytesTransferred:&done completionTimeout:2.0 error:&e];
    if (!ok) fprintf(stderr, "usb: bulk out ep%d failed: %s\n", ep, e.localizedDescription.UTF8String);
    if (ok && d.length % (_highSpeed ? 512 : 64) == 0) {
        NSMutableData *z = [NSMutableData data];
        [_out[ep] sendIORequestWithData:z bytesTransferred:&done completionTimeout:1.0 error:nil];
    }
    return ok;
}

- (void)submitRx {
    if (!_rxRunning) return;
    NSMutableData *buf = [NSMutableData dataWithLength:RX_BUF_SIZE];
    NSError *e = nil;
    __weak RTLUSB *weakSelf = self;
    BOOL ok = [_in enqueueIORequestWithData:buf completionTimeout:0 error:&e
        completionHandler:^(IOReturn status, NSUInteger done) {
            RTLUSB *s = weakSelf;
            if (!s || !s->_rxRunning) return;
            if (status == kIOReturnSuccess && done > 0) {
                RTLRxHandler h = s->_rxHandler;
                dispatch_async(s->_rxq, ^{ h(buf.bytes, done); });
            } else if (status == kIOReturnNoDevice || status == kIOReturnNotAttached ||
                       status == kIOReturnNotResponding || status == kIOReturnOffline) {
                [s markGone];
                return;
            } else if (status != kIOReturnSuccess && status != kIOReturnAborted) {
                fprintf(stderr, "usb: rx error 0x%x\n", status);
                [NSThread sleepForTimeInterval:0.01];
            }
            [s submitRx];
        }];
    if (!ok) fprintf(stderr, "usb: rx enqueue failed: %s\n", e.localizedDescription.UTF8String);
}

- (void)startRx:(RTLRxHandler)handler {
    _rxHandler = [handler copy];
    _rxRunning = YES;
    for (int i = 0; i < RX_INFLIGHT; i++) [self submitRx];
}

- (void)stopRx {
    if (!_rxRunning) return;
    _rxRunning = NO;
    if (!_gone) [_in abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
}
@end
