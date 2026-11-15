#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
USER_UID=$(stat -f %u /dev/console)

make
launchctl bootout system/local.rtl8821au.daemon 2>/dev/null || true
launchctl bootout gui/$USER_UID/local.rtl8821au.menu 2>/dev/null || true
for i in $(seq 20); do
  launchctl print system/local.rtl8821au.daemon >/dev/null 2>&1 || launchctl print gui/$USER_UID/local.rtl8821au.menu >/dev/null 2>&1 || break
  sleep 0.5
done

install -d -m 755 /usr/local/libexec/rtl8821au
install -m 755 rtl8821au /usr/local/libexec/rtl8821au/rtl8821au
install -m 644 firmware/rtw8821a_fw.bin /usr/local/libexec/rtl8821au/rtw8821a_fw.bin
rm -rf "/Applications/RTL Wi-Fi.app"
cp -R RTLWiFi.app "/Applications/RTL Wi-Fi.app"
install -m 644 launchd/local.rtl8821au.daemon.plist /Library/LaunchDaemons/
install -m 644 launchd/local.rtl8821au.menu.plist /Library/LaunchAgents/
chown root:wheel /Library/LaunchDaemons/local.rtl8821au.daemon.plist /Library/LaunchAgents/local.rtl8821au.menu.plist

launchctl bootstrap system /Library/LaunchDaemons/local.rtl8821au.daemon.plist
launchctl bootstrap gui/$USER_UID /Library/LaunchAgents/local.rtl8821au.menu.plist || true
echo "Installed. Look for the Wi-Fi icon in the menu bar. Log: /var/log/rtl8821au.log"
