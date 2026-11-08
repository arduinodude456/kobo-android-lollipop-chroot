/* SPDX-License-Identifier: MIT */
#ifndef KOBO_INPUT_H
#define KOBO_INPUT_H
#include <stdint.h>
struct kobo_input {
    int touch, keyboard, touching;
    uint32_t width, height;
    char touch_node[4096], keyboard_node[4096];
    unsigned char keys[256];
};
int kobo_input_create(struct kobo_input *, const char *input_dir, uint32_t, uint32_t);
void kobo_input_destroy(struct kobo_input *);
int kobo_input_pointer(struct kobo_input *, unsigned mask, unsigned x, unsigned y);
int kobo_input_key(struct kobo_input *, uint32_t keysym, int down);
int kobo_probe(void);
#endif
