#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t   s8;
typedef int16_t  s16;
typedef int32_t  s32;

#ifndef BIT
#define BIT(n) (1u << (n))
#endif
#define GENMASK(h, l) ((~0u >> (31 - (h))) & (~0u << (l)))

#define MASKBYTE0   0xff
#define MASKBYTE1   0xff00
#define MASKBYTE2   0xff0000
#define MASKBYTE3   0xff000000
#define MASKHWORD   0xffff0000
#define MASKLWORD   0x0000ffff
#define MASKDWORD   0xffffffff
#define RFREG_MASK  0xfffff
#define INV_RF_DATA 0xffffffff

static inline unsigned rtw_ffs(u32 mask) { return mask ? (unsigned)__builtin_ctz(mask) : 0; }
static inline u32 field_get(u32 mask, u32 v) { return (v & mask) >> rtw_ffs(mask); }
static inline u32 field_prep(u32 mask, u32 v) { return (v << rtw_ffs(mask)) & mask; }
