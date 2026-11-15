#pragma once
#import <Foundation/Foundation.h>
#include "compat.h"

NS_ASSUME_NONNULL_BEGIN

@interface RTLNetif : NSObject
@property(readonly) NSString *ifname;
@property(copy, nullable) void (^onFrame)(const u8 *frame, size_t len);

- (nullable instancetype)initWithMAC:(const u8 *)mac error:(NSError **)err;
- (void)start;
- (BOOL)inject:(const u8 *)frame len:(size_t)len;
- (void)setLinkUp:(BOOL)up;
- (void)setMAC:(const u8 *)mac;
- (void)destroy;
+ (BOOL)installServiceForInterface:(NSString *)ifname;
+ (BOOL)removeServiceForInterface:(NSString *)ifname;
@end

NS_ASSUME_NONNULL_END
