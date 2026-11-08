# SPDX-License-Identifier: MIT
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := libkobofb
LOCAL_MODULE_TAGS := optional
LOCAL_SRC_FILES := kobofb.c kobo_fb.c kobo_binder.c kobo_log.c kobo_net.c
LOCAL_CFLAGS := -std=gnu99 -Os -Wall -Wextra
LOCAL_SHARED_LIBRARIES := libc
include $(BUILD_SHARED_LIBRARY)

include $(CLEAR_VARS)
LOCAL_MODULE := kobo-vnc
LOCAL_MODULE_TAGS := optional
LOCAL_SRC_FILES := kobo_vnc.c kobo_fb.c kobo_input.c
LOCAL_CFLAGS := -std=gnu99 -Os -Wall -Wextra
LOCAL_FORCE_STATIC_EXECUTABLE := true
LOCAL_SYSTEM_SHARED_LIBRARIES :=
LOCAL_STATIC_LIBRARIES := libc libm
include $(BUILD_EXECUTABLE)

# Runtime source is maintained separately from these native components.
include $(CLEAR_VARS)
LOCAL_MODULE := kobo-container
LOCAL_MODULE_TAGS := optional
LOCAL_SRC_FILES := ../runtime/kobo-container.c
LOCAL_CFLAGS := -std=gnu99 -Os -Wall -Wextra
LOCAL_FORCE_STATIC_EXECUTABLE := true
LOCAL_SYSTEM_SHARED_LIBRARIES :=
LOCAL_STATIC_LIBRARIES := libc libm
include $(BUILD_EXECUTABLE)
