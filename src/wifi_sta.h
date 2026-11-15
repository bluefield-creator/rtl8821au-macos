#pragma once
#import <Foundation/Foundation.h>
#import "rtl_hal.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, RTLSecurity) { RTLSecOpen, RTLSecWPA2PSK, RTLSecUnsupported };

@interface RTLBss : NSObject
@property NSData *bssid;
@property NSString *ssid;
@property u8 channel;
@property int rssi;
@property u16 capability, beaconInterval;
@property NSData *rates;
@property NSData *_Nullable extRates;
@property RTLSecurity security;
@property NSString *securityDesc;
@property BOOL mfpRequired;
- (NSString *)bssidString;
@end

typedef NS_ENUM(int, RTLStaState) {
    RTLStaIdle, RTLStaAuth, RTLStaAssoc, RTLStaHandshake, RTLStaConnected
};

@interface RTLStation : NSObject
@property(readonly) RTLHal *hal;
@property(readonly) RTLStaState state;
@property(readonly, nullable) RTLBss *bss;
@property(readonly) const u8 *mac;
@property(nonatomic) BOOL verbose;
@property(nonatomic) BOOL autoReconnect;

@property(copy, nullable) void (^onEthernet)(const u8 *frame, size_t len);
@property(copy, nullable) void (^onLinkChange)(BOOL up);

@property(readonly) uint64_t rxData, txData, rxDropped, micFailures;
@property(readonly) int lastRssi;

- (instancetype)initWithHal:(RTLHal *)hal;
- (NSArray<RTLBss *> *)scanForSSID:(nullable NSString *)ssid dwell:(double)dwell include5GHz:(BOOL)five;
- (BOOL)joinBss:(RTLBss *)b passphrase:(nullable NSString *)pass error:(NSError **)err;
- (void)shutdown;
- (BOOL)connectToSSID:(NSString *)ssid passphrase:(nullable NSString *)pass error:(NSError **)err;
- (void)disconnect;
- (BOOL)sendEthernet:(const u8 *)frame len:(size_t)len;
@end

NS_ASSUME_NONNULL_END
