/* SPDX-License-Identifier: MIT */
/*
 * LD_PRELOAD helper that lets KitKat API 19 (32 bit binder ABI, protocol 7) talk to
 * a Linux kernel built without CONFIG_ANDROID_BINDER_IPC_32BIT (64 bit ABI,
 * protocol 8). Only BINDER_VERSION and BINDER_WRITE_READ need translating; all
 * other binder ioctls have identical numbers and payloads on both sides.
 */
#ifndef KOBO_BINDER_H
#define KOBO_BINDER_H
#include <stdint.h>

/* Raw ioctl backend: returns >= 0, or -1 with errno set (like syscall()). */
typedef long (*kobo_binder_sys_fn)(int fd, unsigned long request, void *arg);

/* Non-zero if request must go through kobo_binder_ioctl(). */
int kobo_binder_wants(uint32_t request);
long kobo_binder_ioctl(int fd, unsigned long request, void *arg, kobo_binder_sys_fn sys);

#endif
