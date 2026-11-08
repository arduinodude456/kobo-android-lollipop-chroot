/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "kobo_fb.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static int dimension(const char *name, uint32_t fallback, uint32_t *out)
{
    const char *s = getenv(name); char *end; unsigned long value;
    if (!s) { *out = fallback; return 0; }
    errno = 0; value = strtoul(s, &end, 10);
    if (errno || !*s || *end || value < 1 || value > KOBO_FB_MAX_DIM) {
        errno = EINVAL; return -1;
    }
    *out = (uint32_t)value; return 0;
}
int kobo_fb_dimensions(uint32_t *w, uint32_t *h)
{
    return dimension("KOBO_FB_WIDTH", KOBO_FB_DEFAULT_WIDTH, w) ||
           dimension("KOBO_FB_HEIGHT", KOBO_FB_DEFAULT_HEIGHT, h) ? -1 : 0;
}
void kobo_fb_release(struct kobo_fb *f)
{
    int saved = errno;
    if (f->pixels != MAP_FAILED && f->pixels) munmap(f->pixels, f->bytes);
    if (f->meta != MAP_FAILED && f->meta) munmap(f->meta, sizeof(*f->meta));
    if (f->pixels_fd >= 0) close(f->pixels_fd);
    if (f->meta_fd >= 0) close(f->meta_fd);
    memset(f, 0, sizeof(*f)); f->pixels_fd = f->meta_fd = -1;
    errno = saved;
}
int kobo_fb_snapshot(const struct kobo_fb_meta *src, struct kobo_fb_meta *out)
{
    unsigned i; const volatile struct kobo_fb_meta *v = src;
    for (i = 0; i < 100; ++i) {
        uint32_t a = v->sequence;
        if (a & 1) continue;
        __sync_synchronize(); memcpy(out, src, sizeof(*out)); __sync_synchronize();
        if (v->sequence == a && !(out->sequence & 1)) return 0;
    }
    errno = EAGAIN; return -1;
}
int kobo_fb_create(const char *dir, uint32_t w, uint32_t h, struct kobo_fb *f)
{
    char path[PATH_MAX]; struct stat st; int locked = 0;
    memset(f, 0, sizeof(*f)); f->pixels_fd = f->meta_fd = -1;
    if (!w || !h || w > KOBO_FB_MAX_DIM || h > KOBO_FB_MAX_DIM) {
        errno = EINVAL; return -1;
    }
    f->bytes = (size_t)w * h * 4;
    if (snprintf(path, sizeof(path), "%s/fb.meta", dir) >= (int)sizeof(path)) {
        errno = ENAMETOOLONG; return -1;
    }
    f->meta_fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0660);
    if (f->meta_fd < 0 || flock(f->meta_fd, LOCK_EX) < 0) goto fail;
    locked = 1;
    if (fstat(f->meta_fd, &st) < 0 || !S_ISREG(st.st_mode)) { errno = EINVAL; goto fail; }
    if (st.st_size != 0 && st.st_size != (off_t)sizeof(*f->meta)) { errno = EINVAL; goto fail; }
    if (!st.st_size && ftruncate(f->meta_fd, sizeof(*f->meta)) < 0) goto fail;
    f->meta = mmap(NULL, sizeof(*f->meta), PROT_READ | PROT_WRITE, MAP_SHARED, f->meta_fd, 0);
    if (f->meta == MAP_FAILED) goto fail;
    if (f->meta->magic && (f->meta->magic != KOBO_FB_MAGIC ||
        f->meta->abi_version != KOBO_FB_ABI || f->meta->header_bytes != 64 ||
        f->meta->width != w || f->meta->height != h || f->meta->stride != w * 2 ||
        f->meta->yoffset > h || (f->meta->sequence & 1))) { errno = EINVAL; goto fail; }
    if (snprintf(path, sizeof(path), "%s/fb.bin", dir) >= (int)sizeof(path)) {
        errno = ENAMETOOLONG; goto fail;
    }
    f->pixels_fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0660);
    if (f->pixels_fd < 0 || fstat(f->pixels_fd, &st) < 0) goto fail;
    if (!S_ISREG(st.st_mode)) { errno = EINVAL; goto fail; }
    if (st.st_size != 0 && st.st_size != (off_t)f->bytes) { errno = EINVAL; goto fail; }
    if (!st.st_size && ftruncate(f->pixels_fd, (off_t)f->bytes) < 0) goto fail;
    f->pixels = mmap(NULL, f->bytes, PROT_READ | PROT_WRITE, MAP_SHARED, f->pixels_fd, 0);
    if (f->pixels == MAP_FAILED) goto fail;
    if (!f->meta->magic) {
        struct kobo_fb_meta initial;
        memset(&initial, 0, sizeof(initial)); initial.abi_version = KOBO_FB_ABI;
        initial.header_bytes = sizeof(initial); initial.width = w;
        initial.height = h; initial.stride = w * 2;
        memcpy(f->meta, &initial, sizeof(initial)); __sync_synchronize();
        f->meta->magic = KOBO_FB_MAGIC;
    }
    flock(f->meta_fd, LOCK_UN); return 0;
fail:
    { int e = errno; if (locked) flock(f->meta_fd, LOCK_UN);
      errno = e; kobo_fb_release(f); return -1; }
}
int kobo_fb_flip(struct kobo_fb *f, uint32_t yoffset)
{
    if (yoffset > f->meta->height) { errno = EINVAL; return -1; }
    if (flock(f->meta_fd, LOCK_EX) < 0) return -1;
    __sync_add_and_fetch(&f->meta->sequence, 1);
    f->meta->yoffset = yoffset;
    ++f->meta->frame_counter;
    __sync_synchronize(); __sync_add_and_fetch(&f->meta->sequence, 1);
    flock(f->meta_fd, LOCK_UN); return 0;
}
