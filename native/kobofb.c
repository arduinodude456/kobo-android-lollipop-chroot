/* SPDX-License-Identifier: MIT */
/* This translation unit defines libc entry points. KitKat's fortified fcntl.h
 * otherwise also defines inline open/openat functions under platform flags. */
#ifdef _FORTIFY_SOURCE
#undef _FORTIFY_SOURCE
#endif
#define _GNU_SOURCE
#define _LARGEFILE64_SOURCE
#include "kobo_fb.h"
#include "kobo_binder.h"
#include "kobo_net.h"
#include "kobo_log.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
/* Android NDK r10e's ARM32 syscall.h exposes __NR_* constants but does not
 * provide the SYS_* aliases that glibc normally supplies. Keep the source
 * usable with both old Bionic and modern libc headers. */
#ifndef SYS_openat
#ifdef __NR_openat
#define SYS_openat __NR_openat
#endif
#endif
#ifndef SYS_close
#ifdef __NR_close
#define SYS_close __NR_close
#endif
#endif
#ifndef SYS_dup
#ifdef __NR_dup
#define SYS_dup __NR_dup
#endif
#endif
#ifndef SYS_dup2
#ifdef __NR_dup2
#define SYS_dup2 __NR_dup2
#endif
#endif
#ifndef SYS_dup3
#ifdef __NR_dup3
#define SYS_dup3 __NR_dup3
#endif
#endif
#ifndef SYS_ioctl
#ifdef __NR_ioctl
#define SYS_ioctl __NR_ioctl
#endif
#endif
#ifndef SYS_fsync
#ifdef __NR_fsync
#define SYS_fsync __NR_fsync
#endif
#endif
#ifndef SYS_fdatasync
#ifdef __NR_fdatasync
#define SYS_fdatasync __NR_fdatasync
#endif
#endif
#ifndef FBIO_WAITFORVSYNC
#define FBIO_WAITFORVSYNC _IOW('F', 0x20, uint32_t)
#endif

/* Raw syscall forwarding avoids dlsym/bootstrap recursion on old bionic. No
 * constructor, fd registry, mmap emulation, or dependency on Android libutils. */
static struct kobo_fb shared;
static int initialized;
static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;
static const char *shared_dir(void)
{
    const char *p = getenv("KOBO_FB_DIR");
    return p && *p ? p : "/dev/kobo";
}
static int initialize(void)
{
    uint32_t w, h; int rc = 0;
    pthread_mutex_lock(&init_lock);
    if (!initialized) {
        if (kobo_fb_dimensions(&w, &h) < 0 ||
            kobo_fb_create(shared_dir(), w, h, &shared) < 0) rc = -1;
        else initialized = 1;
    }
    pthread_mutex_unlock(&init_lock); return rc;
}
static int redirect(int dirfd, const char *path)
{
    struct stat a, b;
    if (!path) return 0;
    if (!strcmp(path, "/dev/fb0") || !strcmp(path, "/dev/graphics/fb0")) return 1;
    if (strcmp(path, "fb0")) return 0;
    if (dirfd == AT_FDCWD) {
        if (stat(".", &a)) return 0;
    } else if (fstat(dirfd, &a)) return 0;
    if (!stat("/dev", &b) && a.st_dev == b.st_dev && a.st_ino == b.st_ino) return 1;
    return !stat("/dev/graphics", &b) && a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}
static int do_open(int dirfd, const char *path, int flags, mode_t mode)
{
    char target[4096];
    if (kobo_net_hides_path(path, flags)) path = "/dev/null";   /* netd darf Host-sysctl nicht schreiben */
    if (redirect(dirfd, path)) {
        if (initialize() < 0) return -1;
        if (flags & (O_TRUNC | O_EXCL | O_DIRECTORY)) { errno = EINVAL; return -1; }
        if (snprintf(target, sizeof(target), "%s/fb.bin", shared_dir()) >= (int)sizeof(target)) {
            errno = ENAMETOOLONG; return -1;
        }
        return (int)syscall(SYS_openat, AT_FDCWD, target, flags & ~O_CREAT, mode);
    }
    return (int)syscall(SYS_openat, dirfd, path, flags, mode);
}
static int has_mode(int flags)
{
#ifdef O_TMPFILE
    return (flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE);
#else
    return flags & O_CREAT;
#endif
}
#define OPEN_WRAPPER(name) \
int name(const char *path, int flags, ...) { \
    mode_t mode = 0; if (has_mode(flags)) { va_list ap; va_start(ap, flags); \
    mode = (mode_t)va_arg(ap, int); va_end(ap); } \
    return do_open(AT_FDCWD, path, flags, mode); }
OPEN_WRAPPER(open)
OPEN_WRAPPER(open64)
#define OPENAT_WRAPPER(name) \
int name(int dirfd, const char *path, int flags, ...) { \
    mode_t mode = 0; if (has_mode(flags)) { va_list ap; va_start(ap, flags); \
    mode = (mode_t)va_arg(ap, int); va_end(ap); } \
    return do_open(dirfd, path, flags, mode); }
OPENAT_WRAPPER(openat)
OPENAT_WRAPPER(openat64)
/* Fortify entry points used by both glibc and Android framework builds. */
int __open_2(const char *p, int f) { if (has_mode(f)) { errno=EINVAL; return -1; } return do_open(AT_FDCWD,p,f,0); }
int __open64_2(const char *p, int f) { return __open_2(p,f); }
int __openat_2(int d, const char *p, int f) { if (has_mode(f)) { errno=EINVAL; return -1; } return do_open(d,p,f,0); }
int __openat64_2(int d, const char *p, int f) { return __openat_2(d,p,f); }
int close(int fd) { return (int)syscall(SYS_close, fd); }
int dup(int fd) { return (int)syscall(SYS_dup, fd); }
int dup2(int oldfd, int newfd)
{
#ifdef SYS_dup2
    return (int)syscall(SYS_dup2, oldfd, newfd);
#else
    if (oldfd == newfd) return fcntl(oldfd, F_GETFD) < 0 ? -1 : oldfd;
    return (int)syscall(SYS_dup3, oldfd, newfd, 0);
#endif
}
#ifdef SYS_dup3
int dup3(int oldfd, int newfd, int flags) { return (int)syscall(SYS_dup3, oldfd, newfd, flags); }
#endif
static int fake_fd(int fd)
{
    struct stat a, b; char path[4096]; int saved = errno, match = 0;
    if (fstat(fd, &a) < 0) return 0;
    if (snprintf(path, sizeof(path), "%s/fb.bin", shared_dir()) < (int)sizeof(path) &&
        !stat(path, &b) && S_ISREG(a.st_mode) && a.st_dev == b.st_dev && a.st_ino == b.st_ino)
        match = 1;
    errno = saved; return match;
}
/* fsync()/fdatasync() sind auf dem Chroot-Image extrem teuer: ext4-Journal in einer Datei auf FAT32, jeder
 * Aufruf zieht Journal-Commit und Flush bis zur eMMC nach sich. Android ruft sie staendig auf (SQLite, AtomicFile
 * in system_server, Package-/Settings-Dateien). Standard: Erfolg melden, ohne zu warten. Datenverlust ist nur
 * bei hartem Stromausfall moeglich (ext4 commit-Intervall); "android.sh stop" synchronisiert normal.
 * Abschalten: KOBO_NOSYNC=0 (config). Ein ungueltiger Deskriptor liefert weiter EBADF. */
static int nosync_mode = -1;
static int nosync(void)
{
    if (nosync_mode < 0) nosync_mode = kobo_tunable("KOBO_NOSYNC", 1) != 0;
    return nosync_mode;
}
int fsync(int fd)
{
    if (nosync()) return fcntl(fd, F_GETFD) < 0 ? -1 : 0;
    return (int)syscall(SYS_fsync, fd);
}
int fdatasync(int fd)
{
    if (nosync()) return fcntl(fd, F_GETFD) < 0 ? -1 : 0;
    return (int)syscall(SYS_fdatasync, fd);
}
static void varinfo(struct fb_var_screeninfo *v)
{
    memset(v, 0, sizeof(*v));
    v->xres = v->xres_virtual = shared.meta->width;
    v->yres = shared.meta->height; v->yres_virtual = v->yres * 2;
    v->yoffset = shared.meta->yoffset; v->bits_per_pixel = 16;
    v->red.offset = 11; v->red.length = 5;
    v->green.offset = 5; v->green.length = 6; v->blue.length = 5;
    v->height = v->width = (uint32_t)-1;
    v->vmode = FB_VMODE_NONINTERLACED;
}
static int valid_var(const struct fb_var_screeninfo *v)
{
    unsigned activate = v->activate & FB_ACTIVATE_MASK;
    return v->xres == shared.meta->width && v->yres == shared.meta->height &&
        v->xres_virtual == v->xres && v->yres_virtual == v->yres * 2 &&
        !v->xoffset && v->yoffset <= v->yres && v->bits_per_pixel == 16 &&
        !v->grayscale && !v->nonstd && !v->rotate && !v->vmode &&
        v->red.offset == 11 && v->red.length == 5 && !v->red.msb_right &&
        v->green.offset == 5 && v->green.length == 6 && !v->green.msb_right &&
        !v->blue.offset && v->blue.length == 5 && !v->blue.msb_right &&
        !v->transp.offset && !v->transp.length && !v->transp.msb_right &&
        (activate == FB_ACTIVATE_NOW || activate == FB_ACTIVATE_VBL || activate == FB_ACTIVATE_TEST);
}
static long raw_ioctl(int fd, unsigned long request, void *arg)
{
    return syscall(SYS_ioctl, fd, request, arg);
}
#ifdef __BIONIC__
int ioctl(int fd, int request, ...)
#else
int ioctl(int fd, unsigned long request, ...)
#endif
{
    void *arg = NULL; va_list ap;
    /* These Linux ioctls really have no third argument. Others, including old
     * direction-less FBIO* requests, have a pointer or scalar third argument. */
    if (request != FIOCLEX && request != FIONCLEX
#ifdef TIOCEXCL
        && request != TIOCEXCL && request != TIOCNXCL
#endif
    ) { va_start(ap, request); arg = va_arg(ap, void *); va_end(ap); }
    if (kobo_net_blocks((unsigned long)request, arg)) return 0;
    /* KitKat API 19 userspace speaks the 32 bit binder ABI, the kernel the 64 bit one. */
    if (kobo_binder_wants((uint32_t)request)) return (int)kobo_binder_ioctl(fd, (unsigned long)request, arg, raw_ioctl);
    /* Framebuffer-ioctls haben den Typ 'F' (0x46xx). Alles andere (ashmem, binder-fremde, tty, FIONREAD ...)
     * geht ohne die beiden Zusatz-Syscalls (fstat+stat) aus fake_fd() direkt zum Kernel. */
    if ((((uint32_t)request >> 8) & 0xff) != 'F' || !fake_fd(fd))
        return (int)syscall(SYS_ioctl, fd, request, arg);
    if (initialize() < 0) return -1;
    switch ((unsigned long)request) {
    case FBIOGET_VSCREENINFO:
        if (!arg) break;
        varinfo(arg); return 0;
    case FBIOGET_FSCREENINFO: {
        struct fb_fix_screeninfo *f = arg;
        if (!f) break;
        memset(f, 0, sizeof(*f)); memcpy(f->id, "kobo-fakefb", 11);
        f->smem_len = (uint32_t)shared.bytes; f->type = FB_TYPE_PACKED_PIXELS;
        f->visual = FB_VISUAL_TRUECOLOR; f->ypanstep = 1;
        f->line_length = shared.meta->stride; f->accel = FB_ACCEL_NONE; return 0;
    }
    case FBIOPUT_VSCREENINFO:
    case FBIOPAN_DISPLAY: {
        struct fb_var_screeninfo *v = arg;
        if (!v) break;
        if (!valid_var(v)) { errno = EINVAL; return -1; }
        if ((v->activate & FB_ACTIVATE_MASK) == FB_ACTIVATE_TEST) return 0;
        return kobo_fb_flip(&shared, v->yoffset);
    }
    case FBIO_WAITFORVSYNC:
        if (!arg) break;
        if (*(uint32_t *)arg != 0) { errno = EINVAL; return -1; }
        /* Fake display: no hardware vblank. Keep only a 1 ms yield so the
         * emulated display is not artificially capped at about 62.5 Hz. */
        usleep(1000); return 0;
    case FBIOBLANK:
        if ((uintptr_t)arg <= FB_BLANK_POWERDOWN) return 0;
        errno = EINVAL; return -1;
    default:
        /* Preserve normal fd operations (e.g. FIOCLEX) and kernel errno. */
        return (int)syscall(SYS_ioctl, fd, request, arg);
    }
    errno = EFAULT; return -1;
}
