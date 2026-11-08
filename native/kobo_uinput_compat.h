/* SPDX-License-Identifier: MIT */
#ifndef KOBO_UINPUT_COMPAT_H
#define KOBO_UINPUT_COMPAT_H

#include <stdint.h>
#include <sys/ioctl.h>
#include <linux/input.h>

/* NDK r10e's API-21 ARM sysroot has linux/input.h but omits linux/uinput.h.
 * These definitions are the stable legacy uinput ABI used by Lollipop. */
#ifndef UINPUT_IOCTL_BASE
#define UINPUT_IOCTL_BASE 'U'
#endif
#ifndef UINPUT_MAX_NAME_SIZE
#define UINPUT_MAX_NAME_SIZE 80
#endif
#ifndef ABS_CNT
#define ABS_CNT (ABS_MAX + 1)
#endif
#ifndef BUS_VIRTUAL
#define BUS_VIRTUAL 0x06
#endif

#ifndef UI_SET_EVBIT
#define UI_SET_EVBIT _IOW(UINPUT_IOCTL_BASE, 100, int)
#define UI_SET_KEYBIT _IOW(UINPUT_IOCTL_BASE, 101, int)
#define UI_SET_RELBIT _IOW(UINPUT_IOCTL_BASE, 102, int)
#define UI_SET_ABSBIT _IOW(UINPUT_IOCTL_BASE, 103, int)
#define UI_SET_MSCBIT _IOW(UINPUT_IOCTL_BASE, 104, int)
#define UI_SET_LEDBIT _IOW(UINPUT_IOCTL_BASE, 105, int)
#define UI_SET_SNDBIT _IOW(UINPUT_IOCTL_BASE, 106, int)
#define UI_SET_FFBIT _IOW(UINPUT_IOCTL_BASE, 107, int)
#define UI_SET_PHYS _IOW(UINPUT_IOCTL_BASE, 108, char *)
#define UI_SET_SWBIT _IOW(UINPUT_IOCTL_BASE, 109, int)
#define UI_SET_PROPBIT _IOW(UINPUT_IOCTL_BASE, 110, int)
#endif
#ifndef UI_BEGIN_FF_UPLOAD
#define UI_BEGIN_FF_UPLOAD _IOWR(UINPUT_IOCTL_BASE, 200, int)
#define UI_END_FF_UPLOAD _IOW(UINPUT_IOCTL_BASE, 201, int)
#endif
#ifndef UI_DEV_CREATE
#define UI_DEV_CREATE _IO(UINPUT_IOCTL_BASE, 1)
#define UI_DEV_DESTROY _IO(UINPUT_IOCTL_BASE, 2)
#endif

#ifndef KOBO_UINPUT_USER_DEV_DEFINED
#define KOBO_UINPUT_USER_DEV_DEFINED
struct uinput_user_dev {
    char name[UINPUT_MAX_NAME_SIZE];
    struct input_id id;
    uint32_t ff_effects_max;
    int32_t absmax[ABS_CNT];
    int32_t absmin[ABS_CNT];
    int32_t absfuzz[ABS_CNT];
    int32_t absflat[ABS_CNT];
};
#endif

#endif
