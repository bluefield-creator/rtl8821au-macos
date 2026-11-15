#!/bin/bash
set -uo pipefail
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
USER_UID=$(stat -f %u /dev/console)
launchctl bootout gui/$USER_UID/local.rtl8821au.menu 2>/dev/null
launchctl bootout system/local.rtl8821au.daemon 2>/dev/null
/usr/local/libexec/rtl8821au/rtl8821au remove-service 2>/dev/null
rm -f /Library/LaunchDaemons/local.rtl8821au.daemon.plist /Library/LaunchAgents/local.rtl8821au.menu.plist
rm -rf /usr/local/libexec/rtl8821au "/Applications/RTL Wi-Fi.app"
ifconfig feth8021 destroy 2>/dev/null; ifconfig feth8022 destroy 2>/dev/null
[ "${1:-}" = "--purge" ] && rm -rf "/Library/Application Support/rtl8821au"
echo "Uninstalled."
