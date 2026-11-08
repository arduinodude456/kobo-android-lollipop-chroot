# SPDX-License-Identifier: MIT
CC ?= cc
BUILD_DIR ?= build
CPPFLAGS ?=
CFLAGS ?= -Os -g0 -std=gnu99 -Wall -Wextra -Wformat=2
LDFLAGS ?=
STATIC ?= 1
ifeq ($(STATIC),1)
VNC_STATIC = -static
endif
.PHONY: all clean test libkobofb.so kobo-vnc
all: $(BUILD_DIR)/libkobofb.so $(BUILD_DIR)/kobo-vnc $(BUILD_DIR)/kobo-wpa
libkobofb.so: $(BUILD_DIR)/libkobofb.so
kobo-vnc: $(BUILD_DIR)/kobo-vnc
$(BUILD_DIR):
	mkdir -p $@
$(BUILD_DIR)/libkobofb.so: kobofb.c kobo_fb.c kobo_fb.h kobo_binder.c kobo_log.c kobo_net.c kobo_net.h kobo_binder.h kobo_binder_abi.h kobo_log.h | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -fPIC -shared -pthread kobofb.c kobo_fb.c kobo_binder.c kobo_log.c kobo_net.c $(LDFLAGS) -Wl,-soname,libkobofb.so -o $@
$(BUILD_DIR)/kobo-wpa: kobo_wifi.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) kobo_wifi.c $(LDFLAGS) $(VNC_STATIC) -o $@
$(BUILD_DIR)/kobo-vnc: kobo_vnc.c kobo_fb.c kobo_input.c kobo_fb.h kobo_input.h | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) kobo_vnc.c kobo_fb.c kobo_input.c $(LDFLAGS) $(VNC_STATIC) -o $@
test:
	cd .. && python3 -m unittest discover -s tests -p test_native.py -v
clean:
	rm -rf $(BUILD_DIR)
# Example musl cross-build (shim is NOT Android-compatible when built with musl):
# make CC=arm-linux-musleabihf-gcc BUILD_DIR=build-arm STATIC=1 kobo-vnc
# Build the Android preload library with Android.mk / the platform bionic toolchain.
