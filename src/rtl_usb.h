#pragma once
#import <Foundation/Foundation.h>
#include "compat.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^RTLRxHandler)(const uint8_t *buf, size_t len);

@interface RTLUSB : NSObject
@property(readonly) uint16_t vendorID, productID;
@property(readonly) NSString *productName;
@property(readonly) int bulkOutCount;
@property(readonly) BOOL highSpeed;

+ (nullable instancetype)openFirstSupported:(NSError **)err;

- (u8)rd8:(u16)addr;
- (u16)rd16:(u16)addr;
- (u32)rd32:(u16)addr;
- (void)wr8:(u16)addr val:(u8)v;
- (void)wr16:(u16)addr val:(u16)v;
- (void)wr32:(u16)addr val:(u32)v;
- (BOOL)writeBlock:(u16)addr data:(const void *)d len:(u16)len;

- (BOOL)bulkOut:(int)ep data:(NSData *)d;
- (void)startRx:(RTLRxHandler)handler;
- (void)stopRx;

@property(readonly) uint64_t ctrlErrors;
@property(readonly) BOOL gone;
@property(copy, nullable) void (^onRemoved)(void);
- (void)close;
@end

NS_ASSUME_NONNULL_END
