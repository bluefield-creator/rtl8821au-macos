CC      = clang
CFLAGS  = -O2 -g -Wall -Wextra -Wno-unused-parameter -Isrc -fobjc-arc
LDFLAGS = -framework Foundation -framework IOKit -framework IOUSBHost -framework SystemConfiguration

SRCS = src/main.m src/rtl_usb.m src/rtl_hal.m src/rtl_rx.c src/wifi_crypto.c src/wifi_sta.m src/netif.m src/daemon.m src/vendor/rtw8821a_tables.c
OBJS = $(patsubst src/%,build/%.o,$(SRCS))

all: rtl8821au RTLWiFi.app

RTLWiFi.app: gui/RTLWiFi.m gui/Info.plist
	@mkdir -p RTLWiFi.app/Contents/MacOS
	cp gui/Info.plist RTLWiFi.app/Contents/Info.plist
	$(CC) -O2 -Wall -fobjc-arc gui/RTLWiFi.m -framework Cocoa -o RTLWiFi.app/Contents/MacOS/RTLWiFi
	codesign --force -s - RTLWiFi.app

rtl8821au: $(OBJS)
	$(CC) $(OBJS) $(LDFLAGS) -o $@

build/%.o: src/%
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf build rtl8821au RTLWiFi.app

.PHONY: all clean
