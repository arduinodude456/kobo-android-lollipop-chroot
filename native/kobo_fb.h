/* SPDX-License-Identifier: MIT */
#ifndef KOBO_FB_H
#define KOBO_FB_H
#include <stdint.h>
#include <stddef.h>

/* All fields are native little-endian uint32_t on supported ARM32 targets.
 * fb.bin: two packed RGB565 pages; byte stride = width*2, page = stride*height.
 * fb.meta: exactly 64 bytes, never prepend this header to the pixel mapping.
 * Writers serialize metadata updates with flock(LOCK_EX); sequence is odd while
 * changing fields and even when stable. Readers retry an odd/changed sequence.
 * frame_counter wraps modulo 2^32 and counts accepted PUT/PAN operations. Direct
 * mmap writes need not change it: consumers must also compare pixel content. */
#define KOBO_FB_MAGIC UINT32_C(0x4b464231)
#define KOBO_FB_ABI 1u
#define KOBO_FB_DEFAULT_WIDTH 600u
#define KOBO_FB_DEFAULT_HEIGHT 800u
#define KOBO_FB_MAX_DIM 4096u
struct kobo_fb_meta {
    uint32_t magic, abi_version, header_bytes;
    uint32_t width, height, stride, yoffset, frame_counter, sequence;
    uint32_t reserved[7];
};
typedef char kobo_fb_meta_size_must_be_64[(sizeof(struct kobo_fb_meta)==64)?1:-1];
struct kobo_fb {
    int pixels_fd, meta_fd;
    size_t bytes;
    unsigned char *pixels;
    struct kobo_fb_meta *meta;
};
int kobo_fb_dimensions(uint32_t *width, uint32_t *height);
int kobo_fb_create(const char *dir, uint32_t width, uint32_t height,
                   struct kobo_fb *fb);
void kobo_fb_release(struct kobo_fb *fb);
int kobo_fb_snapshot(const struct kobo_fb_meta *source, struct kobo_fb_meta *out);
int kobo_fb_flip(struct kobo_fb *fb, uint32_t yoffset);
#endif
