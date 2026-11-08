/* SPDX-License-Identifier: MIT */
/*
 * Binder 32 -> 64 bit ABI translation (see kobo_binder.h / kobo_binder_abi.h).
 *
 * Android KitKat/API 19 userspace talks protocol 7 with 32 bit structures. The Kobo kernel
 * (4.9.77) speaks protocol 8 with 64 bit structures and rejects the 24 byte
 * BINDER_WRITE_READ (0xc0186201) with -EINVAL; only the 48 byte one is known.
 *
 * What is translated, per BINDER_WRITE_READ call:
 *   write stream  userspace BC_* commands are rewritten to the kernel layout in a
 *                 temporary buffer; transaction payloads are rebuilt because
 *                 flat_binder_object grows from 16 to 24 bytes inside the parcel
 *                 data and the offsets array grows from u32 to u64 entries.
 *   read stream   kernel BR_* commands are rewritten to the userspace layout.
 *                 Received transaction data lives in the read-only mmap of the
 *                 driver in kernel layout, so it is copied into a malloc'ed block
 *                 (converted). The block starts with a small header that remembers
 *                 the original kernel pointer; BC_FREE_BUFFER maps the pointer the
 *                 user hands back to that kernel pointer and frees the block.
 *   BINDER_VERSION reports 7 instead of 8.
 *
 * There is no global state besides the optional log, so every thread can call this
 * concurrently. Consumed counters are mapped back to userspace command boundaries.
 */
#include "kobo_binder.h"
#include "kobo_binder_abi.h"
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define KB_MAX_STREAM   (1u << 20)   /* sane bound for one read/write stream */
#define KB_MAX_TX_DATA  (8u << 20)   /* binder itself caps buffers at 4 MiB */
#define KB_BUF_MAGIC    0x4b42554du  /* "KBUM" */

struct kb_buf_hdr { uint32_t magic, pad; uint64_t kptr; };   /* 16 bytes, 8-aligned */
KB_ASSERT(hdr, sizeof(struct kb_buf_hdr) == 16);

/* ---- tiny optional log (KOBO_BINDER_LOG=/path), at most 200 lines/process ---- */
static void note(const char *fmt, ...)
{
    static volatile int lines;
    const char *path = getenv("KOBO_BINDER_LOG");
    char buf[256]; va_list ap; int n, fd, saved = errno;
    if (!path || !*path || lines >= 200) return;
    lines++;
    n = snprintf(buf, sizeof(buf), "[%d] ", (int)getpid());
    va_start(ap, fmt);
    n += vsnprintf(buf + n, sizeof(buf) - (size_t)n - 2, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n > sizeof(buf) - 2) n = (int)sizeof(buf) - 2;
    buf[n++] = '\n';
    fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0666);
    if (fd >= 0) { if (write(fd, buf, (size_t)n) < 0) { /* ignore */ } close(fd); }
    errno = saved;
}

/* ---- unaligned access helpers ---- */
static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static void wr32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void wr64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static void cpy(void *d, const void *s, size_t n) { if (n) memcpy(d, s, n); }
static const uint8_t *uptr(uint32_t v) { return (const uint8_t *)(uintptr_t)v; }
static int fit32(uint64_t v, uint32_t *out)
{
    if (v >> 32) { errno = EOVERFLOW; return -1; }
    *out = (uint32_t)v; return 0;
}
static int obj_type_ok(uint32_t t)
{
    return t == KB_TYPE_BINDER || t == KB_TYPE_WEAK_BINDER || t == KB_TYPE_HANDLE ||
           t == KB_TYPE_WEAK_HANDLE || t == KB_TYPE_FD;
}
static int obj_is_local(uint32_t t) { return t == KB_TYPE_BINDER || t == KB_TYPE_WEAK_BINDER; }

/* ---- scratch allocations that live until the ioctl returns ---- */
struct ctx { void **blk; size_t n, cap; };
static void *ctx_alloc(struct ctx *c, size_t sz)
{
    void *p;
    if (c->n == c->cap) {
        size_t nc = c->cap ? c->cap * 2 : 8;
        void **nb = realloc(c->blk, nc * sizeof(*nb));
        if (!nb) { errno = ENOMEM; return NULL; }
        c->blk = nb; c->cap = nc;
    }
    p = malloc(sz ? sz : 1);
    if (!p) { errno = ENOMEM; return NULL; }
    c->blk[c->n++] = p; return p;
}
static void ctx_free(struct ctx *c)
{
    while (c->n) free(c->blk[--c->n]);
    free(c->blk); c->blk = NULL; c->cap = 0;
}

/* ---- transaction: userspace -> kernel ---- */
static int tr_u2k(struct ctx *c, const kb_u_tr *u, kb_k_tr *k)
{
    const uint8_t *ud = uptr(u->buffer), *uo = uptr(u->offsets);
    uint32_t ds = u->data_size, os = u->offsets_size, n, i, prev_end = 0;
    size_t in = 0, out = 0;
    uint8_t *kd; uint64_t *ko;
    if (ds > KB_MAX_TX_DATA || (os & 3u)) { errno = EINVAL; return -1; }
    n = os / 4u;
    if (n > ds / sizeof(kb_u_obj)) { errno = EINVAL; return -1; }
    if ((ds && !ud) || (n && !uo)) { errno = EFAULT; return -1; }
    kd = ctx_alloc(c, (size_t)ds + 8u * (size_t)n);
    ko = ctx_alloc(c, 8u * (size_t)n);
    if (!kd || !ko) return -1;
    for (i = 0; i < n; i++) {
        uint32_t off = rd32(uo + 4u * i);
        kb_u_obj o; kb_k_obj p;
        if (off < prev_end || off > ds || ds - off < sizeof(o)) { errno = EINVAL; return -1; }
        cpy(kd + out, ud + in, off - in); out += off - in; in = off;
        memcpy(&o, ud + off, sizeof(o));
        if (!obj_type_ok(o.type)) { errno = EINVAL; return -1; }
        memset(&p, 0, sizeof(p));
        p.type = o.type; p.flags = o.flags;
        p.binder_or_handle = o.binder_or_handle; p.cookie = o.cookie;   /* zero extend */
        ko[i] = out;
        memcpy(kd + out, &p, sizeof(p)); out += sizeof(p);
        in += sizeof(o); prev_end = off + (uint32_t)sizeof(o);
    }
    cpy(kd + out, ud + in, ds - in); out += ds - in;
    memset(k, 0, sizeof(*k));
    k->target = u->target; k->cookie = u->cookie; k->code = u->code; k->flags = u->flags;
    k->sender_pid = u->sender_pid; k->sender_euid = u->sender_euid;
    k->data_size = out; k->offsets_size = 8u * (uint64_t)n;
    k->buffer = (uint64_t)(uintptr_t)kd; k->offsets = (uint64_t)(uintptr_t)ko;
    return 0;
}

/* ---- transaction: kernel -> userspace (copies out of the driver's mmap) ---- */
static int tr_k2u(const kb_k_tr *k, kb_u_tr *u)
{
    const uint8_t *kd = (const uint8_t *)(uintptr_t)k->buffer;
    const uint8_t *ko = (const uint8_t *)(uintptr_t)k->offsets;
    uint64_t ds = k->data_size, os = k->offsets_size, n, i, prev_end = 0;
    size_t in = 0, out = 0, nds, offs_at, total;
    struct kb_buf_hdr *h; uint8_t *blk, *data, *offs;
    if (ds > KB_MAX_TX_DATA || (os & 7u)) { errno = EPROTO; return -1; }
    n = os / 8u;
    if (n > ds / sizeof(kb_k_obj)) { errno = EPROTO; return -1; }
    if ((ds && !kd) || (n && !ko)) { errno = EPROTO; return -1; }
    nds = (size_t)(ds - 8u * n);
    offs_at = (nds + 3u) & ~(size_t)3u;
    total = sizeof(*h) + offs_at + 4u * (size_t)n;
    blk = malloc(total);
    if (!blk) { errno = ENOMEM; return -1; }
    h = (struct kb_buf_hdr *)blk; h->magic = KB_BUF_MAGIC; h->pad = 0; h->kptr = k->buffer;
    data = blk + sizeof(*h); offs = data + offs_at;
    for (i = 0; i < n; i++) {
        uint64_t off; kb_k_obj p; kb_u_obj o;
        memcpy(&off, ko + 8u * i, 8);
        if (off < prev_end || off > ds || ds - off < sizeof(p)) { errno = EPROTO; goto fail; }
        cpy(data + out, kd + in, (size_t)off - in); out += (size_t)off - in; in = (size_t)off;
        memcpy(&p, kd + off, sizeof(p));
        if (!obj_type_ok(p.type)) { errno = EPROTO; goto fail; }
        o.type = p.type; o.flags = p.flags;
        if (obj_is_local(p.type)) {
            if (fit32(p.binder_or_handle, &o.binder_or_handle) < 0 || fit32(p.cookie, &o.cookie) < 0) goto fail;
        } else {
            o.binder_or_handle = (uint32_t)p.binder_or_handle; o.cookie = (uint32_t)p.cookie;
        }
        wr32(offs + 4u * i, (uint32_t)out);
        memcpy(data + out, &o, sizeof(o)); out += sizeof(o);
        in += sizeof(p); prev_end = off + sizeof(p);
    }
    cpy(data + out, kd + in, (size_t)ds - in);
    memset(u, 0, sizeof(*u));
    if (fit32(k->target, &u->target) < 0 || fit32(k->cookie, &u->cookie) < 0) goto fail;
    u->code = k->code; u->flags = k->flags; u->sender_pid = k->sender_pid; u->sender_euid = k->sender_euid;
    u->data_size = (uint32_t)nds; u->offsets_size = 4u * (uint32_t)n;
    u->buffer = (uint32_t)(uintptr_t)data; u->offsets = (uint32_t)(uintptr_t)offs;
    return 0;
fail:
    free(blk); return -1;
}

/* ---- command tables ---- */
enum kind { C_COPY, C_TR, C_FREE, C_PTRCOOKIE, C_PRIPTRCOOKIE, C_HANDLECOOKIE, C_PTR };
struct cmd { uint32_t from, to; uint8_t from_len, to_len, kind; };
#define SAME(c, n) { c, c, n, n, C_COPY }
static const struct cmd write_cmds[] = {   /* userspace -> kernel */
    { KB_U_BC_TRANSACTION, KB_K_BC_TRANSACTION, 40, 64, C_TR },
    { KB_U_BC_REPLY, KB_K_BC_REPLY, 40, 64, C_TR },
    SAME(KB_BC_ACQUIRE_RESULT, 4),
    { KB_U_BC_FREE_BUFFER, KB_K_BC_FREE_BUFFER, 4, 8, C_FREE },
    SAME(KB_BC_INCREFS, 4), SAME(KB_BC_ACQUIRE, 4), SAME(KB_BC_RELEASE, 4), SAME(KB_BC_DECREFS, 4),
    { KB_U_BC_INCREFS_DONE, KB_K_BC_INCREFS_DONE, 8, 16, C_PTRCOOKIE },
    { KB_U_BC_ACQUIRE_DONE, KB_K_BC_ACQUIRE_DONE, 8, 16, C_PTRCOOKIE },
    SAME(KB_BC_ATTEMPT_ACQUIRE, 8),
    SAME(KB_BC_REGISTER_LOOPER, 0), SAME(KB_BC_ENTER_LOOPER, 0), SAME(KB_BC_EXIT_LOOPER, 0),
    { KB_U_BC_REQUEST_DEATH, KB_K_BC_REQUEST_DEATH, 8, 12, C_HANDLECOOKIE },
    { KB_U_BC_CLEAR_DEATH, KB_K_BC_CLEAR_DEATH, 8, 12, C_HANDLECOOKIE },
    { KB_U_BC_DEAD_DONE, KB_K_BC_DEAD_DONE, 4, 8, C_PTR },
};
static const struct cmd read_cmds[] = {    /* kernel -> userspace ("from" = kernel) */
    { KB_K_BR_TRANSACTION, KB_U_BR_TRANSACTION, 64, 40, C_TR },
    { KB_K_BR_REPLY, KB_U_BR_REPLY, 64, 40, C_TR },
    SAME(KB_BR_ERROR, 4), SAME(KB_BR_OK, 0), SAME(KB_BR_ACQUIRE_RESULT, 4),
    SAME(KB_BR_DEAD_REPLY, 0), SAME(KB_BR_TRANSACTION_COMPLETE, 0),
    { KB_K_BR_INCREFS, KB_U_BR_INCREFS, 16, 8, C_PTRCOOKIE },
    { KB_K_BR_ACQUIRE, KB_U_BR_ACQUIRE, 16, 8, C_PTRCOOKIE },
    { KB_K_BR_RELEASE, KB_U_BR_RELEASE, 16, 8, C_PTRCOOKIE },
    { KB_K_BR_DECREFS, KB_U_BR_DECREFS, 16, 8, C_PTRCOOKIE },
    { KB_K_BR_ATTEMPT_ACQUIRE, KB_U_BR_ATTEMPT_ACQUIRE, 24, 12, C_PRIPTRCOOKIE },
    SAME(KB_BR_NOOP, 0), SAME(KB_BR_SPAWN_LOOPER, 0), SAME(KB_BR_FINISHED, 0),
    { KB_K_BR_DEAD_BINDER, KB_U_BR_DEAD_BINDER, 8, 4, C_PTR },
    { KB_K_BR_CLEAR_DEATH_DONE, KB_U_BR_CLEAR_DEATH_DONE, 8, 4, C_PTR },
    SAME(KB_BR_FAILED_REPLY, 0),
};
static const struct cmd *find_cmd(const struct cmd *t, size_t n, uint32_t code)
{
    size_t i;
    for (i = 0; i < n; i++) if (t[i].from == code) return &t[i];
    return NULL;
}
#define NELEM(a) (sizeof(a) / sizeof((a)[0]))

/* ---- userspace -> kernel command stream ---- */
static int translate_write(struct ctx *c, const uint8_t *u, size_t usz, uint8_t *k, size_t *ksz)
{
    size_t up = 0, kp = 0;
    while (up < usz) {
        const struct cmd *m; const uint8_t *src; uint8_t *dst;
        if (usz - up < 4) { errno = EINVAL; return -1; }
        m = find_cmd(write_cmds, NELEM(write_cmds), rd32(u + up));
        if (!m) { note("unknown BC command 0x%08x", rd32(u + up)); errno = EINVAL; return -1; }
        if (usz - up - 4 < m->from_len) { errno = EINVAL; return -1; }
        src = u + up + 4; dst = k + kp + 4;
        wr32(k + kp, m->to);
        switch (m->kind) {
        case C_COPY: cpy(dst, src, m->from_len); break;
        case C_TR: {
            kb_u_tr ut; kb_k_tr kt;
            memcpy(&ut, src, sizeof(ut));
            if (tr_u2k(c, &ut, &kt) < 0) { note("BC transaction rejected: errno %d", errno); return -1; }
            memcpy(dst, &kt, sizeof(kt)); break;
        }
        case C_FREE: {
            uint32_t p = rd32(src); const struct kb_buf_hdr *h = (const struct kb_buf_hdr *)(uintptr_t)(p - sizeof(*h));
            wr64(dst, p && h->magic == KB_BUF_MAGIC ? h->kptr : (uint64_t)p); break;
        }
        case C_PTRCOOKIE: wr64(dst, rd32(src)); wr64(dst + 8, rd32(src + 4)); break;
        case C_HANDLECOOKIE: wr32(dst, rd32(src)); wr64(dst + 4, rd32(src + 4)); break;
        case C_PTR: wr64(dst, rd32(src)); break;
        default: errno = EINVAL; return -1;
        }
        up += 4u + m->from_len; kp += 4u + m->to_len;
    }
    *ksz = kp; return 0;
}

/* How much of the userspace write stream did the kernel really consume? Also
 * releases the receive blocks of every BC_FREE_BUFFER the kernel has accepted. */
static size_t map_consumed(const uint8_t *u, size_t usz, uint64_t kconsumed)
{
    size_t up = 0; uint64_t kp = 0;
    while (usz - up >= 4) {
        const struct cmd *m = find_cmd(write_cmds, NELEM(write_cmds), rd32(u + up));
        if (!m || usz - up - 4 < m->from_len || kp + 4u + m->to_len > kconsumed) break;
        if (m->kind == C_FREE) {
            uint32_t p = rd32(u + up + 4);
            struct kb_buf_hdr *h = (struct kb_buf_hdr *)(uintptr_t)(p - sizeof(*h));
            if (p && h->magic == KB_BUF_MAGIC) { h->magic = 0; free(h); }
        }
        up += 4u + m->from_len; kp += 4u + m->to_len;
    }
    return up;
}

static void kernel_free(int fd, uint64_t kptr, kobo_binder_sys_fn sys)
{
    uint8_t buf[12]; kb_k_write_read w; int saved = errno;
    wr32(buf, KB_K_BC_FREE_BUFFER); wr64(buf + 4, kptr);
    memset(&w, 0, sizeof(w)); w.write_size = sizeof(buf); w.write_buffer = (uint64_t)(uintptr_t)buf;
    sys(fd, KB_K_WRITE_READ, &w);
    errno = saved;
}

/* ---- kernel -> userspace command stream; returns bytes produced ---- */
static size_t translate_read(int fd, const uint8_t *k, size_t ksz, uint8_t *u, size_t ucap,
                             kobo_binder_sys_fn sys, int *err)
{
    size_t kp = 0, up = 0;
    while (kp < ksz) {
        const struct cmd *m; const uint8_t *src; uint8_t *dst;
        if (ksz - kp < 4) { *err = EPROTO; break; }
        m = find_cmd(read_cmds, NELEM(read_cmds), rd32(k + kp));
        if (!m || ksz - kp - 4 < m->from_len) {
            note("unknown BR command 0x%08x", rd32(k + kp)); *err = EPROTO; break;
        }
        if (ucap - up < 4u + m->to_len) { *err = EPROTO; break; }
        src = k + kp + 4; dst = u + up + 4;
        switch (m->kind) {
        case C_COPY: cpy(dst, src, m->from_len); break;
        case C_TR: {
            kb_k_tr kt; kb_u_tr ut;
            memcpy(&kt, src, sizeof(kt));
            if (tr_k2u(&kt, &ut) < 0) {
                note("BR transaction dropped: errno %d", errno);
                kernel_free(fd, kt.buffer, sys);
                kp += 4u + m->from_len;
                if (m->from == KB_K_BR_REPLY) {   /* wake the waiting caller */
                    wr32(u + up, KB_BR_FAILED_REPLY); up += 4;
                }
                continue;
            }
            memcpy(dst, &ut, sizeof(ut)); break;
        }
        case C_PTRCOOKIE: {
            kb_k_ptr_cookie p; kb_u_ptr_cookie q;
            memcpy(&p, src, sizeof(p));
            if (fit32(p.ptr, &q.ptr) < 0 || fit32(p.cookie, &q.cookie) < 0) { *err = errno; goto done; }
            memcpy(dst, &q, sizeof(q)); break;
        }
        case C_PRIPTRCOOKIE: {
            kb_k_pri_ptr_cookie p; kb_u_pri_ptr_cookie q;
            memcpy(&p, src, sizeof(p)); q.priority = p.priority;
            if (fit32(p.ptr, &q.ptr) < 0 || fit32(p.cookie, &q.cookie) < 0) { *err = errno; goto done; }
            memcpy(dst, &q, sizeof(q)); break;
        }
        case C_PTR: {
            uint64_t v; uint32_t w; memcpy(&v, src, 8);
            if (fit32(v, &w) < 0) { *err = errno; goto done; }
            wr32(dst, w); break;
        }
        default: *err = EPROTO; goto done;
        }
        wr32(u + up, m->to);
        kp += 4u + m->from_len; up += 4u + m->to_len;
    }
done:
    return up;
}

int kobo_binder_wants(uint32_t request)
{
    return request == KB_U_WRITE_READ || request == KB_VERSION;
}

long kobo_binder_ioctl(int fd, unsigned long request, void *arg, kobo_binder_sys_fn sys)
{
    static volatile int announced;
    uint32_t req = (uint32_t)request;
    kb_u_write_read ub; kb_k_write_read kb;
    struct ctx c = { NULL, 0, 0 };
    uint8_t *kwrite = NULL, *kread = NULL;
    size_t ksz = 0, produced = 0, mapped;
    int conv_err = 0, saved; long ret;
    if (!announced) { announced = 1; note("binder shim active (32->64 bit, protocol 7 <-> 8)"); }
    if (req == KB_VERSION) {
        ret = sys(fd, request, arg);
        if (ret >= 0 && arg) {
            int32_t v; memcpy(&v, arg, 4);
            if (v == KB_PROTOCOL_KERNEL) { v = KB_PROTOCOL_USER; memcpy(arg, &v, 4); }
        }
        return ret;
    }
    if (req != KB_U_WRITE_READ) return sys(fd, request, arg);
    if (!arg) { errno = EFAULT; return -1; }
    memcpy(&ub, arg, sizeof(ub));
    /* libbinder and servicemanager always start with zero consumed counters. */
    if (ub.write_consumed || ub.read_consumed || ub.write_size > KB_MAX_STREAM || ub.read_size > KB_MAX_STREAM) {
        errno = EINVAL; return -1;
    }
    if ((ub.write_size && !ub.write_buffer) || (ub.read_size && !ub.read_buffer)) { errno = EFAULT; return -1; }
    memset(&kb, 0, sizeof(kb));
    if (ub.write_size) {
        kwrite = ctx_alloc(&c, 2u * (size_t)ub.write_size + 16u);
        if (!kwrite || translate_write(&c, uptr(ub.write_buffer), ub.write_size, kwrite, &ksz) < 0) {
            saved = errno; ctx_free(&c); errno = saved; return -1;
        }
        kb.write_size = ksz; kb.write_buffer = (uint64_t)(uintptr_t)kwrite;
    }
    if (ub.read_size) {
        kread = ctx_alloc(&c, ub.read_size);
        if (!kread) { saved = errno; ctx_free(&c); errno = saved; return -1; }
        kb.read_size = ub.read_size; kb.read_buffer = (uint64_t)(uintptr_t)kread;
    }
    ret = sys(fd, KB_K_WRITE_READ, &kb);
    saved = errno;
    /* The driver writes the counters back even when it fails after partial work. */
    mapped = ub.write_size ? map_consumed(uptr(ub.write_buffer), ub.write_size, kb.write_consumed) : 0;
    if (ub.read_size && kb.read_consumed)
        produced = translate_read(fd, kread, (size_t)(kb.read_consumed > ub.read_size ? ub.read_size : kb.read_consumed),
                                  (uint8_t *)(uintptr_t)ub.read_buffer, ub.read_size, sys, &conv_err);
    ub.write_consumed = (uint32_t)mapped; ub.read_consumed = (uint32_t)produced;
    memcpy(arg, &ub, sizeof(ub));
    ctx_free(&c);
    if (conv_err) note("read stream translation error %d", conv_err);
    if (ret >= 0 && conv_err) { errno = conv_err; return -1; }
    errno = saved;
    return ret;
}
