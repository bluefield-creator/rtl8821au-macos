#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>

#define RTL_REQ           0x05
#define REG_SYS_ISO_CTRL  0x0000
#define REG_SYS_FUNC_EN   0x0002
#define REG_SYS_CLKR      0x0008
#define REG_EFUSE_CTRL    0x0030
#define REG_EFUSE_TEST    0x0034
#define REG_SYS_CFG       0x00F0
#define REG_EFUSE_ACCESS  0x00CF
#define EFUSE_ACCESS_ON   0x69
#define EFUSE_ACCESS_OFF  0x00

#define EFUSE_PHYS_LEN    512
#define EFUSE_MAP_LEN     512
#define MAC_OFS_8821AU    0x107
#define MAC_OFS_8812AU    0x0D7

static IOUSBHostDevice *gDev;

static BOOL ctrl(uint8_t reqType, uint16_t addr, void *buf, uint16_t len) {
    IOUSBDeviceRequest r = {
        .bmRequestType = reqType, .bRequest = RTL_REQ,
        .wValue = addr, .wIndex = 0, .wLength = len,
    };
    NSUInteger done = 0;
    NSError *err = nil;
    NSMutableData *d = [NSMutableData dataWithBytes:buf length:len];
    BOOL ok = [gDev sendDeviceRequest:r data:d bytesTransferred:&done
                    completionTimeout:1.0 error:&err];
    if (!ok || done != len) {
        fprintf(stderr, "  ! ctrl %s 0x%04x failed: %s\n",
                (reqType & 0x80) ? "read" : "write", addr,
                err.localizedDescription.UTF8String ?: "short transfer");
        return NO;
    }
    if (reqType & 0x80) memcpy(buf, d.bytes, len);
    return YES;
}

static uint8_t  rd8 (uint16_t a) { uint8_t  v = 0; ctrl(0xC0, a, &v, 1); return v; }
static uint32_t rd32(uint16_t a) { uint32_t v = 0; ctrl(0xC0, a, &v, 4); return CFSwapInt32LittleToHost(v); }
static void     wr8 (uint16_t a, uint8_t v) { ctrl(0x40, a, &v, 1); }

static int efuse_read_byte(uint16_t addr) {
    wr8(REG_EFUSE_CTRL + 1, addr & 0xFF);
    wr8(REG_EFUSE_CTRL + 2, (rd8(REG_EFUSE_CTRL + 2) & 0xFC) | ((addr >> 8) & 0x03));
    wr8(REG_EFUSE_CTRL + 3, rd8(REG_EFUSE_CTRL + 3) & 0x7F);
    for (int i = 0; i < 1000; i++) {
        if (rd32(REG_EFUSE_CTRL) & 0x80000000u)
            return rd8(REG_EFUSE_CTRL);
    }
    return -1;
}

static BOOL efuse_logical_map(uint8_t map[EFUSE_MAP_LEN], int *usedOut) {
    memset(map, 0xFF, EFUSE_MAP_LEN);
    wr8(REG_EFUSE_ACCESS, EFUSE_ACCESS_ON);
    uint8_t t = rd8(REG_EFUSE_TEST + 1);
    wr8(REG_EFUSE_TEST + 1, t & ~0x03);

    int p = 0;
    BOOL ok = YES;
    while (p < EFUSE_PHYS_LEN) {
        int hdr = efuse_read_byte(p++);
        if (hdr < 0) { ok = NO; break; }
        if (hdr == 0xFF) break;
        int offset, wordEn;
        if ((hdr & 0x1F) == 0x0F) {
            int hdr2 = efuse_read_byte(p++);
            if (hdr2 < 0) { ok = NO; break; }
            if ((hdr2 & 0x0F) == 0x0F) continue;
            offset = ((hdr2 & 0xF0) >> 1) | ((hdr >> 5) & 0x07);
            wordEn = hdr2 & 0x0F;
        } else {
            offset = (hdr >> 4) & 0x0F;
            wordEn = hdr & 0x0F;
        }
        for (int w = 0; w < 4; w++) {
            if (wordEn & (1 << w)) continue;
            int lo = efuse_read_byte(p++), hi = efuse_read_byte(p++);
            if (lo < 0 || hi < 0) { ok = NO; break; }
            int la = offset * 8 + w * 2;
            if (la + 1 < EFUSE_MAP_LEN) { map[la] = lo; map[la + 1] = hi; }
        }
        if (!ok) break;
    }
    wr8(REG_EFUSE_ACCESS, EFUSE_ACCESS_OFF);
    if (usedOut) *usedOut = p;
    return ok;
}

static void hexdump(const uint8_t *b, int n) {
    for (int i = 0; i < n; i += 16) {
        BOOL blank = YES;
        for (int j = 0; j < 16; j++) if (b[i + j] != 0xFF) blank = NO;
        if (blank) continue;
        printf("    %03x:", i);
        for (int j = 0; j < 16; j++) printf(" %02x", b[i + j]);
        printf("\n");
    }
}

static const struct { uint16_t vid, pid; const char *name; } kKnown[] = {
    {0x2357, 0x0120, "TP-Link Archer T2U Plus (RTL8821AU)"},
    {0x2357, 0x011E, "TP-Link Archer T2U Nano (RTL8821AU)"},
    {0x2357, 0x011F, "TP-Link Archer T2U v3 (RTL8821AU)"},
    {0x0BDA, 0x0811, "Realtek RTL8811AU/8821AU reference"},
    {0x0BDA, 0x0821, "Realtek RTL8821AU reference"},
    {0x0BDA, 0x8812, "Realtek RTL8812AU reference"},
};

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL dumpEfuse = argc > 1 && !strcmp(argv[1], "--efuse");

        io_service_t svc = IO_OBJECT_NULL;
        const char *name = NULL;
        for (size_t i = 0; i < sizeof kKnown / sizeof *kKnown && !svc; i++) {
            CFMutableDictionaryRef m =
                [IOUSBHostDevice createMatchingDictionaryWithVendorID:@(kKnown[i].vid)
                    productID:@(kKnown[i].pid) bcdDevice:nil deviceClass:nil
                    deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:nil];
            svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
            name = kKnown[i].name;
        }
        if (!svc) { fprintf(stderr, "No supported Realtek dongle found.\n"); return 1; }
        printf("Found: %s\n", name);

        NSError *err = nil;
        dispatch_queue_t q = dispatch_queue_create("rtlprobe", DISPATCH_QUEUE_SERIAL);
        gDev = [[IOUSBHostDevice alloc] initWithIOService:svc
                    options:IOUSBHostObjectInitOptionsNone queue:q error:&err
                    interestHandler:nil];
        IOObjectRelease(svc);
        if (!gDev) {
            fprintf(stderr, "Could not open device: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }

        uint32_t cfg = rd32(REG_SYS_CFG);
        printf("\nREG_SYS_CFG (0x00F0) = 0x%08x\n", cfg);
        printf("  chip type : %s\n", (cfg & (1u << 23)) ? "TEST chip" : "normal (production)");
        printf("  fab       : %s\n", (cfg & (1u << 19)) ? "UMC" : "TSMC");
        printf("  cut       : %c-cut\n", 'A' + ((cfg >> 12) & 0x0F));
        printf("  BT func   : %s\n", (cfg & (1u << 16)) ? "present" : "absent");
        printf("REG_SYS_ISO_CTRL = 0x%04x  REG_SYS_FUNC_EN = 0x%04x  REG_SYS_CLKR = 0x%04x\n",
               rd8(REG_SYS_ISO_CTRL) | rd8(REG_SYS_ISO_CTRL + 1) << 8,
               rd8(REG_SYS_FUNC_EN)  | rd8(REG_SYS_FUNC_EN + 1) << 8,
               rd8(REG_SYS_CLKR)     | rd8(REG_SYS_CLKR + 1) << 8);

        uint8_t map[EFUSE_MAP_LEN];
        int used = 0;
        if (!efuse_logical_map(map, &used)) {
            fprintf(stderr, "eFuse read failed partway (got %d bytes).\n", used);
        }
        printf("\neFuse: %d / %d physical bytes in use\n", used, EFUSE_PHYS_LEN);
        printf("  EEPROM ID : 0x%02x%02x %s\n", map[1], map[0],
               (map[0] == 0x29 && map[1] == 0x81) ? "(valid 0x8129 signature)" : "(unexpected!)");

        const uint8_t *mac = map + MAC_OFS_8821AU;
        if (mac[0] == 0xFF) mac = map + MAC_OFS_8812AU;
        printf("  MAC addr  : %02x:%02x:%02x:%02x:%02x:%02x\n",
               mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        printf("  USB VID/PID in eFuse: %04x:%04x\n",
               map[0x100] | map[0x101] << 8, map[0x102] | map[0x103] << 8);

        if (dumpEfuse) {
            printf("\nLogical eFuse map (rows of all-FF omitted):\n");
            hexdump(map, EFUSE_MAP_LEN);
        }
    }
    return 0;
}
