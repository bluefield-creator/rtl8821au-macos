#pragma once
#include "compat.h"

struct rtw_pwr_seq_cmd {
    u16 offset;
    u8 cut_mask;
    u8 intf_mask;
    u8 base:4;
    u8 cmd:4;
    u8 mask;
    u8 value;
};

struct rtw_phy_pg_cfg_pair {
    u32 band, rf_path, tx_num, addr, bitmask, data;
};

struct rtw_txpwr_lmt_cfg_pair {
    u8 regd, band, bw, rs, ch;
    s8 txpwr_lmt;
};

#define RTW_PWR_POLLING_CNT   20000
#define RTW_PWR_CMD_READ      0x00
#define RTW_PWR_CMD_WRITE     0x01
#define RTW_PWR_CMD_POLLING   0x02
#define RTW_PWR_CMD_DELAY     0x03
#define RTW_PWR_CMD_END       0x04
#define RTW_PWR_ADDR_MAC      0x00
#define RTW_PWR_ADDR_USB      0x01
#define RTW_PWR_ADDR_PCIE     0x02
#define RTW_PWR_ADDR_SDIO     0x03
#define RTW_PWR_INTF_SDIO_MSK BIT(0)
#define RTW_PWR_INTF_USB_MSK  BIT(1)
#define RTW_PWR_INTF_PCI_MSK  BIT(2)
#define RTW_PWR_INTF_ALL_MSK  (BIT(0) | BIT(1) | BIT(2) | BIT(3))
#define RTW_PWR_CUT_ALL_MSK   0xFF
enum { RTW_PWR_DELAY_US, RTW_PWR_DELAY_MS };

extern const u32 rtw8821a_mac[];   extern const unsigned rtw8821a_mac_size;
extern const u32 rtw8821a_agc[];   extern const unsigned rtw8821a_agc_size;
extern const u32 rtw8821a_bb[];    extern const unsigned rtw8821a_bb_size;
extern const u32 rtw8821a_rf_a[];  extern const unsigned rtw8821a_rf_a_size;
extern const struct rtw_phy_pg_cfg_pair rtw8821a_bb_pg[];
extern const unsigned rtw8821a_bb_pg_size;
extern const struct rtw_txpwr_lmt_cfg_pair rtw8821a_txpwr_lmt[];
extern const unsigned rtw8821a_txpwr_lmt_size;

extern const struct rtw_pwr_seq_cmd *const card_enable_flow_8821a[];
extern const struct rtw_pwr_seq_cmd *const enter_lps_flow_8821a[];
extern const struct rtw_pwr_seq_cmd *const card_disable_flow_8821a[];
