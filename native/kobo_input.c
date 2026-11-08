/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "kobo_input.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include "kobo_uinput_compat.h"
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#ifdef __GLIBC__
#include <sys/sysmacros.h>
#endif
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifndef INPUT_PROP_DIRECT
#define INPUT_PROP_DIRECT 0x01
#endif
static int emit(int fd, unsigned type, unsigned code, int value)
{
    struct input_event e; ssize_t n;
    memset(&e, 0, sizeof(e)); gettimeofday(&e.time, NULL);
    e.type = (unsigned short)type; e.code = (unsigned short)code; e.value = value;
    do { n = write(fd, &e, sizeof(e)); } while (n < 0 && errno == EINTR);
    return n == (ssize_t)sizeof(e) ? 0 : -1;
}
static int open_uinput(void)
{
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) fd = open("/dev/input/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    return fd;
}
static int make_device(int touch, const char *name, unsigned w, unsigned h)
{
    struct uinput_user_dev d; int fd = open_uinput(); unsigned code;
    if (fd < 0) return -1;
    memset(&d, 0, sizeof(d)); snprintf(d.name, sizeof(d.name), "%s", name);
    d.id.bustype = BUS_VIRTUAL; d.id.vendor = 0x4b4f; d.id.product = touch ? 1 : 2;
    d.id.version = 1;
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 || ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0) goto fail;
    if (touch) {
        if (ioctl(fd, UI_SET_EVBIT, EV_ABS) < 0 || ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH) < 0 ||
            ioctl(fd, UI_SET_ABSBIT, ABS_X) < 0 || ioctl(fd, UI_SET_ABSBIT, ABS_Y) < 0 ||
            ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT) < 0) goto fail;
        d.absmin[ABS_X] = d.absmin[ABS_Y] = 0;
        d.absmax[ABS_X] = (int)w - 1; d.absmax[ABS_Y] = (int)h - 1;
    } else {
        /* Enable Linux keyboard keycodes, not mouse buttons or host devices. */
        for (code = 1; code < 256; ++code)
            if (ioctl(fd, UI_SET_KEYBIT, code) < 0) goto fail;
    }
    if (write(fd, &d, sizeof(d)) != (ssize_t)sizeof(d) || ioctl(fd, UI_DEV_CREATE) < 0) goto fail;
    return fd;
fail:
    { int e = errno; close(fd); errno = e; return -1; }
}
static int expose_node(const char *name, const char *dir, char *out, size_t outlen)
{
    unsigned attempt;
    for (attempt = 0; attempt < 100; ++attempt) {
        DIR *d = opendir("/sys/class/input"); struct dirent *entry;
        if (!d) return -1;
        while ((entry = readdir(d))) {
            char path[512], found[128], extra; unsigned major_n, minor_n; FILE *f;
            if (strncmp(entry->d_name, "event", 5) || !entry->d_name[5]) continue;
            { const char *p = entry->d_name + 5; while (*p >= '0' && *p <= '9') ++p; if (*p) continue; }
            snprintf(path, sizeof(path), "/sys/class/input/%s/device/name", entry->d_name);
            f = fopen(path, "r"); if (!f) continue;
            if (!fgets(found, sizeof(found), f)) { fclose(f); continue; }
            fclose(f); found[strcspn(found, "\r\n")] = 0;
            if (strcmp(found, name)) continue;
            snprintf(path, sizeof(path), "/sys/class/input/%s/dev", entry->d_name);
            f = fopen(path, "r"); if (!f) continue;
            if (fscanf(f, "%u:%u%c", &major_n, &minor_n, &extra) < 2) { fclose(f); continue; }
            fclose(f);
            if (snprintf(out, outlen, "%s/%s", dir, entry->d_name) >= (int)outlen) {
                closedir(d); errno = ENAMETOOLONG; out[0] = 0; return -1;
            }
            /* Never replace or import an existing node, even on a name collision. */
            if (mknod(out, S_IFCHR | 0600, makedev(major_n, minor_n)) < 0) {
                closedir(d); out[0] = 0; return -1;
            }
            if (chown(out, 1000, 1004) < 0 || chmod(out, 0660) < 0) {
                int e = errno; unlink(out); out[0] = 0; closedir(d); errno = e; return -1;
            }
            closedir(d); return 0;
        }
        closedir(d); usleep(10000);
    }
    errno = ETIMEDOUT; return -1;
}
void kobo_input_destroy(struct kobo_input *i)
{
    if (i->touch >= 0) { ioctl(i->touch, UI_DEV_DESTROY); close(i->touch); }
    if (i->keyboard >= 0) { ioctl(i->keyboard, UI_DEV_DESTROY); close(i->keyboard); }
    if (i->touch_node[0]) unlink(i->touch_node);
    if (i->keyboard_node[0]) unlink(i->keyboard_node);
    i->touch = i->keyboard = -1; i->touch_node[0] = i->keyboard_node[0] = 0;
}
int kobo_input_create(struct kobo_input *i, const char *dir, uint32_t w, uint32_t h)
{
    char touch_name[80], key_name[80]; struct timespec ts; struct stat st;
    memset(i, 0, sizeof(*i)); i->touch = i->keyboard = -1; i->width = w; i->height = h;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    snprintf(touch_name, sizeof(touch_name), "kobo-vnc-touch-%ld-%lx", (long)getpid(), (unsigned long)ts.tv_nsec);
    snprintf(key_name, sizeof(key_name), "kobo-vnc-key-%ld-%lx", (long)getpid(), (unsigned long)ts.tv_nsec);
    if (dir && (lstat(dir, &st) < 0 || !S_ISDIR(st.st_mode))) { errno = ENOTDIR; return -1; }
    i->touch = make_device(1, touch_name, w, h);
    if (i->touch < 0) goto fail;
    i->keyboard = make_device(0, key_name, w, h);
    if (i->keyboard < 0) goto fail;
    if (dir && (expose_node(touch_name, dir, i->touch_node, sizeof(i->touch_node)) < 0 ||
                expose_node(key_name, dir, i->keyboard_node, sizeof(i->keyboard_node)) < 0)) goto fail;
    return 0;
fail:
    { int e = errno; kobo_input_destroy(i); errno = e; return -1; }
}
int kobo_input_pointer(struct kobo_input *i, unsigned mask, unsigned x, unsigned y)
{
    int down = !!(mask & 1);
    if (i->touch < 0) return 0;
    if (x >= i->width) x = i->width - 1;
    if (y >= i->height) y = i->height - 1;
    if (emit(i->touch, EV_ABS, ABS_X, (int)x) || emit(i->touch, EV_ABS, ABS_Y, (int)y) ||
        emit(i->touch, EV_KEY, BTN_TOUCH, down) || emit(i->touch, EV_SYN, SYN_REPORT, 0)) return -1;
    i->touching = down; return 0;
}
static int keycode(uint32_t sym)
{
    static const unsigned short letters[26] = {
        KEY_A,KEY_B,KEY_C,KEY_D,KEY_E,KEY_F,KEY_G,KEY_H,KEY_I,KEY_J,KEY_K,KEY_L,KEY_M,
        KEY_N,KEY_O,KEY_P,KEY_Q,KEY_R,KEY_S,KEY_T,KEY_U,KEY_V,KEY_W,KEY_X,KEY_Y,KEY_Z};
    if (sym >= 'a' && sym <= 'z') return letters[sym-'a'];
    if (sym >= 'A' && sym <= 'Z') return letters[sym-'A'];
    if (sym >= '1' && sym <= '9') return KEY_1 + (int)(sym-'1');
    if (sym == '0') return KEY_0;
    switch (sym) {
    case 0xff50: case 0xffeb: case 0x1008ff18: return KEY_HOME;
    case 0xff1b: case 0x1008ff26: return KEY_BACK;
    case 0xff08: return KEY_BACKSPACE;
    case 0xff67: case 0xffbe: return KEY_MENU;
    case 0xff51: return KEY_LEFT; case 0xff52: return KEY_UP;
    case 0xff53: return KEY_RIGHT; case 0xff54: return KEY_DOWN;
    case 0xff0d: case 0xff8d: return KEY_ENTER;
    case 0xff09: return KEY_TAB; case 0xffff: return KEY_DELETE;
    case 0xffe1: return KEY_LEFTSHIFT; case 0xffe2: return KEY_RIGHTSHIFT;
    case 0xffe3: return KEY_LEFTCTRL; case 0xffe4: return KEY_RIGHTCTRL;
    case 0xffe9: return KEY_LEFTALT; case 0xffea: return KEY_RIGHTALT;
    case ' ': return KEY_SPACE; case '-': return KEY_MINUS; case '=': return KEY_EQUAL;
    case '[': return KEY_LEFTBRACE; case ']': return KEY_RIGHTBRACE;
    case ';': return KEY_SEMICOLON; case '\'': return KEY_APOSTROPHE;
    case ',': return KEY_COMMA; case '.': return KEY_DOT; case '/': return KEY_SLASH;
    case '\\': return KEY_BACKSLASH; case '`': return KEY_GRAVE;
    default: return 0;
    }
}
static int unsafe_no_namespaces(void)
{
    const char *value = getenv("KOBO_ALLOW_UNSAFE_NO_NAMESPACES");
    return value && !strcmp(value, "1");
}
int kobo_input_key(struct kobo_input *i, uint32_t sym, int down)
{
    int code = keycode(sym);
    if (!code || i->keyboard < 0) return 0;
    if (emit(i->keyboard, EV_KEY, (unsigned)code, down ? (i->keys[code] ? 2 : 1) : 0) ||
        emit(i->keyboard, EV_SYN, SYN_REPORT, 0)) return -1;
    i->keys[code] = !!down; return 0;
}

struct binder_version_kitkat { int32_t protocol_version; };
#define ANDROID_BINDER_VERSION_32BIT _IOWR('b', 9, struct binder_version_kitkat)
/* Android ashmem uses the Linux UAPI magic 0x77 ('w'), not 'a'. */
#define KOBO_ASHMEM_SET_SIZE _IOW(0x77, 3, size_t)
#define KOBO_ASHMEM_GET_SIZE _IO(0x77, 4)
static const char *device_env(const char *env, const char *fallback)
{
    const char *p = getenv(env); return p && *p ? p : fallback;
}
int kobo_probe(void)
{
    int failed = 0, fd, status; pid_t pid; struct kobo_input input;
    const char *p = device_env("KOBO_BINDER_DEVICE", "/dev/binder");
    struct binder_version_kitkat v;
    fd = open(p, O_RDWR | O_CLOEXEC); memset(&v, 0, sizeof(v));
    if (fd < 0) { fprintf(stderr, "binder: cannot open %s: %s\n", p, strerror(errno)); failed = 1; }
    else {
        if (ioctl(fd, ANDROID_BINDER_VERSION_32BIT, &v) < 0) {
            fprintf(stderr, "binder: BINDER_VERSION on %s: %s\n", p, strerror(errno)); failed = 1;
        } else if (v.protocol_version != 7 && v.protocol_version != 8) {
            fprintf(stderr, "binder: unsupported protocol %d, need Android Binder protocol 7 or 8\n", v.protocol_version); failed = 1;
        } else if (v.protocol_version == 8) {
            /* 64-bit binder ABI (kernel without CONFIG_ANDROID_BINDER_IPC_32BIT).
             * KitKat API 19 speaks the 32-bit ABI; libkobofb.so (kobo_binder.c)
             * translates BINDER_VERSION and BINDER_WRITE_READ in every process. */
            fprintf(stderr, "binder: protocol 8 (64-bit ABI), translated by libkobofb.so\n");
        } else fprintf(stderr, "binder: protocol 7 OK\n");
        close(fd);
    }
    p = device_env("KOBO_ASHMEM_DEVICE", "/dev/ashmem");
    fd = open(p, O_RDWR | O_CLOEXEC);
    if (fd < 0) { fprintf(stderr, "ashmem: cannot open %s: %s\n", p, strerror(errno)); failed = 1; }
    else {
        if (ioctl(fd, KOBO_ASHMEM_SET_SIZE, (size_t)4096) < 0 || ioctl(fd, KOBO_ASHMEM_GET_SIZE) != 4096) {
            fprintf(stderr, "ashmem: set/get size ioctl failed on %s: %s\n", p, strerror(errno)); failed = 1;
        } else fprintf(stderr, "ashmem: size ioctls OK\n");
        close(fd);
    }
    if (kobo_input_create(&input, NULL, 600, 800) < 0) {
        fprintf(stderr, "uinput: touchscreen/keyboard creation failed: %s\n", strerror(errno)); failed = 1;
    } else { fprintf(stderr, "uinput: legacy touchscreen/keyboard creation OK\n"); kobo_input_destroy(&input); }
    pid = fork();
    if (!pid) {
#ifdef SYS_unshare
        if (syscall(SYS_unshare, CLONE_NEWNS | CLONE_NEWPID) < 0) {
            if (!unsafe_no_namespaces()) {
                fprintf(stderr, "namespaces: unshare mount/pid failed: %s\n", strerror(errno)); _exit(1);
            }
            fprintf(stderr, "namespaces: unavailable; unsafe chroot fallback enabled\n"); _exit(0);
        } else _exit(0);
#else
        if (unsafe_no_namespaces()) {
            fprintf(stderr, "namespaces: syscall unavailable; unsafe chroot fallback enabled\n"); _exit(0);
        }
        fprintf(stderr, "namespaces: unshare syscall unavailable\n"); _exit(1);
#endif
    }
    if (pid < 0) { perror("namespaces: fork"); failed = 1; }
    else {
        do { fd = waitpid(pid, &status, 0); } while (fd < 0 && errno == EINTR);
        if (fd < 0 || !WIFEXITED(status) || WEXITSTATUS(status)) failed = 1;
        else fprintf(stderr, "namespaces: mount/pid OK\n");
    }
    return failed ? 1 : 0;
}
