/* SPDX-License-Identifier: MIT */
/*
 * Functional test of the binder 32 -> 64 bit shim. Must be built for 32 bit ARM
 * (run under qemu-arm): the "userspace" half uses the real 32 bit pointers of an
 * Android-5-like process, the fake "kernel" half uses the real 64 bit uapi header.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/android/binder.h>   /* kernel side: 64 bit layout */
#include "../native/kobo_binder.h"
#include "../native/kobo_binder_abi.h" /* userspace side: kb_u_* / KB_U_* */

/* Count the shim's heap use (linked with -Wl,--wrap=malloc,--wrap=free,--wrap=realloc).
 * The fake kernel uses calloc(), which is not wrapped, so only shim blocks are counted. */
static long live_allocs;
void *__real_malloc(size_t n); void __real_free(void *p); void *__real_realloc(void *p, size_t n);
void *__wrap_malloc(size_t n) { void *p = __real_malloc(n); if (p) live_allocs++; return p; }
void __wrap_free(void *p) { if (p) live_allocs--; __real_free(p); }
void *__wrap_realloc(void *p, size_t n)
{
    void *q = __real_realloc(p, n);
    if (q && !p) live_allocs++;
    if (!q && !n && p) live_allocs--;
    return q;
}

typedef char need_32bit_pointers[sizeof(void *) == 4 ? 1 : -1];
static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

/* ============================ fake 64 bit kernel ============================ */
#define MAXK 256
static struct { uint64_t ptr; int live; } kbuf[MAXK];
static int nkbuf, live_bufs, kcalls, bad_free, unknown_cmd, bad_tx, loopers, fail_at, seen;
static struct { uint32_t cmd; uint64_t a, b; } klog[256];
static int nlog;
static uint8_t queue[16384]; static size_t qlen;
static struct { uint32_t handle, cookie; } dummy_unused;

static void qpush(uint32_t cmd, const void *pl, size_t n)
{
    memcpy(queue + qlen, &cmd, 4); qlen += 4;
    if (n) memcpy(queue + qlen, pl, n);
    qlen += n;
}
static void klogp(uint32_t cmd, uint64_t a, uint64_t b)
{
    klog[nlog].cmd = cmd; klog[nlog].a = a; klog[nlog].b = b; nlog++;
}
static uint64_t kalloc_tracked(void *mem)
{
    uint64_t p = (uint64_t)(uintptr_t)mem;
    kbuf[nkbuf].ptr = p; kbuf[nkbuf].live = 1; nkbuf++; live_bufs++;
    return p;
}
/* what the real driver does with the objects when moving a transaction across */
static void xlate_objects(uint8_t *mem, const uint64_t *offs, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++) {
        struct flat_binder_object f;
        memcpy(&f, mem + offs[i], sizeof(f));
        if (f.hdr.type == BINDER_TYPE_BINDER) { f.hdr.type = BINDER_TYPE_HANDLE; f.handle = 0x10 + (uint32_t)i; f.cookie = 0; }
        else if (f.hdr.type == BINDER_TYPE_HANDLE) { uint32_t hd = f.handle; f.hdr.type = BINDER_TYPE_BINDER; f.binder = 0x1000 + hd; f.cookie = 0x2000 + hd; }
        else if (f.hdr.type == BINDER_TYPE_FD) f.handle += 100;
        memcpy(mem + offs[i], &f, sizeof(f));
    }
}
static void deliver(uint32_t brcmd, const struct binder_transaction_data *tr)
{
    size_t n = (size_t)tr->offsets_size / 8, dsz = (size_t)tr->data_size, asz = (dsz + 7) & ~(size_t)7, i;
    const uint8_t *data = (const uint8_t *)(uintptr_t)tr->data.ptr.buffer;
    const uint8_t *offp = (const uint8_t *)(uintptr_t)tr->data.ptr.offsets;
    uint8_t *mem = calloc(1, asz + n * 8 + 8);
    uint64_t offs[256]; struct binder_transaction_data out;
    memcpy(mem, data, dsz);
    for (i = 0; i < n; i++) memcpy(&offs[i], offp + 8 * i, 8);
    memcpy(mem + asz, offs, n * 8);
    xlate_objects(mem, offs, n);
    out = *tr;
    out.data.ptr.buffer = kalloc_tracked(mem); out.data.ptr.offsets = out.data.ptr.buffer + asz;
    if (brcmd == BR_TRANSACTION) {
        out.target.ptr = 0x1000 + tr->target.handle; out.cookie = 0x2000 + tr->target.handle;
        out.sender_pid = 1234; out.sender_euid = 1000;
    }
    qpush(brcmd, &out, sizeof(out));
}
/* inject a transaction the shim must refuse to translate (unknown object type) */
static void inject_bad_tr(void)
{
    uint8_t *mem = calloc(1, 64); uint64_t off = 0; struct binder_transaction_data t;
    struct flat_binder_object f; memset(&f, 0, sizeof(f)); f.hdr.type = BINDER_TYPE_PTR;
    memcpy(mem, &f, sizeof(f));
    memset(&t, 0, sizeof(t)); t.data_size = 24; t.offsets_size = 8;
    t.data.ptr.buffer = kalloc_tracked(mem);
    memcpy(mem + 32, &off, 8); t.data.ptr.offsets = t.data.ptr.buffer + 32;
    qpush(BR_REPLY, &t, sizeof(t));
}
static int kernel_write(const uint8_t *p, size_t size, uint64_t *consumed)
{
    size_t pos = 0;
    while (pos < size) {
        uint32_t cmd; memcpy(&cmd, p + pos, 4);
        if (++seen == fail_at) { errno = EFAULT; return -1; }
        pos += 4;
        switch (cmd) {
        case BC_TRANSACTION: case BC_REPLY: {
            struct binder_transaction_data t; uint64_t prev_end = 0, off; size_t i, n;
            memcpy(&t, p + pos, sizeof(t)); pos += sizeof(t);
            n = (size_t)t.offsets_size / 8;
            if (t.offsets_size % 8) bad_tx++;
            for (i = 0; i < n; i++) {
                uint32_t type;
                memcpy(&off, (const uint8_t *)(uintptr_t)t.data.ptr.offsets + 8 * i, 8);
                if (off < prev_end || off + sizeof(struct flat_binder_object) > t.data_size) { bad_tx++; break; }
                memcpy(&type, (const uint8_t *)(uintptr_t)t.data.ptr.buffer + off, 4);
                if (type != BINDER_TYPE_BINDER && type != BINDER_TYPE_HANDLE && type != BINDER_TYPE_FD &&
                    type != BINDER_TYPE_WEAK_BINDER && type != BINDER_TYPE_WEAK_HANDLE) bad_tx++;
                prev_end = off + sizeof(struct flat_binder_object);
            }
            if (cmd == BC_TRANSACTION) { qpush(BR_TRANSACTION_COMPLETE, NULL, 0); deliver(BR_TRANSACTION, &t); }
            else deliver(BR_REPLY, &t);
            break;
        }
        case BC_FREE_BUFFER: {
            uint64_t ptr; int i, found = 0; memcpy(&ptr, p + pos, 8); pos += 8;
            for (i = 0; i < nkbuf; i++) if (kbuf[i].ptr == ptr && kbuf[i].live) { kbuf[i].live = 0; live_bufs--; found = 1; }
            if (!found) bad_free++;
            break;
        }
        case BC_INCREFS: case BC_ACQUIRE: case BC_RELEASE: case BC_DECREFS: case BC_ACQUIRE_RESULT: {
            uint32_t v; memcpy(&v, p + pos, 4); pos += 4; klogp(cmd, v, 0); break;
        }
        case BC_INCREFS_DONE: case BC_ACQUIRE_DONE: {
            struct binder_ptr_cookie pc; memcpy(&pc, p + pos, sizeof(pc)); pos += sizeof(pc); klogp(cmd, pc.ptr, pc.cookie); break;
        }
        case BC_ATTEMPT_ACQUIRE: {
            struct binder_pri_desc d; memcpy(&d, p + pos, sizeof(d)); pos += sizeof(d); klogp(cmd, (uint64_t)d.priority, d.desc); break;
        }
        case BC_REQUEST_DEATH_NOTIFICATION: case BC_CLEAR_DEATH_NOTIFICATION: {
            struct binder_handle_cookie hc; memcpy(&hc, p + pos, sizeof(hc)); pos += sizeof(hc); klogp(cmd, hc.handle, hc.cookie); break;
        }
        case BC_DEAD_BINDER_DONE: {
            uint64_t c; memcpy(&c, p + pos, 8); pos += 8; klogp(cmd, c, 0); break;
        }
        case BC_REGISTER_LOOPER: case BC_ENTER_LOOPER: case BC_EXIT_LOOPER: loopers++; break;
        default: unknown_cmd++; errno = EINVAL; return -1;
        }
        *consumed = pos;
    }
    return 0;
}
static long fake_sys(int fd, unsigned long request, void *arg)
{
    (void)fd; kcalls++;
    if ((uint32_t)request == BINDER_VERSION) {
        struct binder_version v; v.protocol_version = BINDER_CURRENT_PROTOCOL_VERSION; memcpy(arg, &v, sizeof(v)); return 0;
    }
    if ((uint32_t)request == BINDER_WRITE_READ) {
        struct binder_write_read w; int rc = 0;
        memcpy(&w, arg, sizeof(w));
        w.write_consumed = 0; w.read_consumed = 0;
        if (w.write_size && kernel_write((const uint8_t *)(uintptr_t)w.write_buffer, (size_t)w.write_size, &w.write_consumed) < 0) rc = -1;
        if (rc == 0 && w.read_size) {
            uint8_t *o = (uint8_t *)(uintptr_t)w.read_buffer; size_t pos = 4;
            uint32_t noop = BR_NOOP; memcpy(o, &noop, 4);
            while (qlen) {
                uint32_t cmd; size_t cl; memcpy(&cmd, queue, 4); cl = 4 + _IOC_SIZE(cmd);
                if (pos + cl > w.read_size) break;
                memcpy(o + pos, queue, cl); pos += cl; qlen -= cl; memmove(queue, queue + cl, qlen);
            }
            w.read_consumed = pos;
        }
        memcpy(arg, &w, sizeof(w));
        return rc;
    }
    errno = ENOTTY; return -1;
}

/* ============================ "KitKat API 19" userspace ============================ */
static uint8_t W[8192], R[8192];
static size_t wl;
static void wc(uint32_t cmd, const void *pl, size_t n)
{
    memcpy(W + wl, &cmd, 4); wl += 4;
    if (n) memcpy(W + wl, pl, n);
    wl += n;
}
static long call(size_t rsz, kb_u_write_read *b)
{
    memset(b, 0, sizeof(*b)); b->write_size = (uint32_t)wl; b->write_buffer = (uint32_t)(uintptr_t)W;
    b->read_size = (uint32_t)rsz; b->read_buffer = rsz ? (uint32_t)(uintptr_t)R : 0;
    return kobo_binder_ioctl(3, KB_U_WRITE_READ, b, fake_sys);
}
static void kreset(void) { nkbuf = 0; live_bufs = 0; qlen = 0; }
static void reset(void)
{
    wl = 0; qlen = 0; nlog = 0; fail_at = 0; seen = 0; kcalls = 0; bad_tx = 0; unknown_cmd = 0; bad_free = 0;
    memset(W, 0, sizeof(W)); memset(R, 0, sizeof(R));
}
/* iterate the userspace read stream */
struct rd { const uint8_t *p; size_t pos, len; };
static int next(struct rd *r, uint32_t *cmd, const uint8_t **pl)
{
    if (r->pos + 4 > r->len) return 0;
    memcpy(cmd, r->p + r->pos, 4);
    *pl = r->p + r->pos + 4; r->pos += 4 + ((*cmd >> 16) & 0x3fff);
    return r->pos <= r->len;
}
static void put_obj(uint8_t *d, uint32_t type, uint32_t flags, uint32_t v, uint32_t cookie)
{
    kb_u_obj o; o.type = type; o.flags = flags; o.binder_or_handle = v; o.cookie = cookie; memcpy(d, &o, sizeof(o));
}

static void test_version(void)
{
    int32_t v = 0; reset();
    CHECK(kobo_binder_wants(KB_VERSION) && kobo_binder_wants(KB_U_WRITE_READ));
    CHECK(!kobo_binder_wants(KB_K_WRITE_READ) && !kobo_binder_wants(0x40046205u));
    CHECK(kobo_binder_ioctl(3, KB_VERSION, &v, fake_sys) == 0);
    CHECK(v == 7);
}

static void test_transaction_roundtrip(void)
{
    uint8_t data[72]; uint32_t offs[3] = { 8, 28, 44 }; kb_u_tr t; kb_u_write_read b; struct rd r;
    uint32_t cmd, seen_cmds = 0; const uint8_t *pl; int got_tr = 0; uint32_t data_ptr = 0;
    kreset(); reset();
    memset(data, 0xAA, sizeof(data));
    put_obj(data + 8, KB_TYPE_BINDER, 0x7f, 0x11223344, 0x55667788);
    put_obj(data + 28, KB_TYPE_HANDLE, 0, 5, 0);
    put_obj(data + 44, KB_TYPE_FD, 0, 7, 0);
    memset(&t, 0, sizeof(t)); t.target = 7; t.code = 3; t.flags = 0; t.data_size = sizeof(data); t.offsets_size = sizeof(offs);
    t.buffer = (uint32_t)(uintptr_t)data; t.offsets = (uint32_t)(uintptr_t)offs;
    wc(KB_BC_ENTER_LOOPER, NULL, 0); wc(KB_U_BC_TRANSACTION, &t, sizeof(t));
    { uint32_t h = 9; wc(KB_BC_INCREFS, &h, 4); }
    CHECK(call(256, &b) == 0);
    CHECK(b.write_consumed == wl);
    CHECK(loopers == 1 && bad_tx == 0 && unknown_cmd == 0);
    CHECK(nlog == 1 && klog[0].cmd == BC_INCREFS && klog[0].a == 9);
    r.p = R; r.pos = 0; r.len = b.read_consumed;
    while (next(&r, &cmd, &pl)) {
        seen_cmds++;
        if (cmd == KB_U_BR_TRANSACTION) {
            kb_u_tr u; const uint8_t *d; const uint32_t *o; kb_u_obj ob; size_t i;
            memcpy(&u, pl, sizeof(u)); got_tr = 1;
            CHECK(u.target == 0x1007 && u.cookie == 0x2007 && u.code == 3 && u.sender_pid == 1234 && u.sender_euid == 1000);
            CHECK(u.data_size == 72 && u.offsets_size == 12);
            d = (const uint8_t *)(uintptr_t)u.buffer; o = (const uint32_t *)(uintptr_t)u.offsets;
            data_ptr = u.buffer;
            CHECK(o[0] == 8 && o[1] == 28 && o[2] == 44);
            for (i = 0; i < 72; i++) {
                int inside = (i >= 8 && i < 24) || (i >= 28 && i < 44) || (i >= 44 && i < 60);
                if (!inside) CHECK(d[i] == 0xAA);
            }
            memcpy(&ob, d + 8, 16);   /* BINDER from sender became HANDLE 0x10 */
            CHECK(ob.type == KB_TYPE_HANDLE && ob.binder_or_handle == 0x10 && ob.flags == 0x7f);
            memcpy(&ob, d + 28, 16);  /* HANDLE 5 became local BINDER 0x1005 / cookie 0x2005 */
            CHECK(ob.type == KB_TYPE_BINDER && ob.binder_or_handle == 0x1005 && ob.cookie == 0x2005);
            memcpy(&ob, d + 44, 16);  /* FD 7 -> 107 */
            CHECK(ob.type == KB_TYPE_FD && ob.binder_or_handle == 107);
        }
    }
    CHECK(seen_cmds == 3 && got_tr);    /* NOOP, TRANSACTION_COMPLETE, TRANSACTION */
    CHECK(live_bufs == 1);
    /* returning the buffer must free exactly the kernel pointer */
    reset(); wc(KB_U_BC_FREE_BUFFER, &data_ptr, 4);
    CHECK(call(0, &b) == 0 && b.write_consumed == wl);
    CHECK(live_bufs == 0 && bad_free == 0);
}

static void test_reply_status(void)
{
    uint32_t status = (uint32_t)-32; kb_u_tr t, u; kb_u_write_read b; struct rd r; uint32_t cmd, p; const uint8_t *pl;
    kreset(); reset();
    memset(&t, 0, sizeof(t)); t.flags = 0x08; t.data_size = 4; t.buffer = (uint32_t)(uintptr_t)&status;
    wc(KB_U_BC_REPLY, &t, sizeof(t));
    CHECK(call(128, &b) == 0);
    r.p = R; r.pos = 0; r.len = b.read_consumed;
    CHECK(next(&r, &cmd, &pl) && cmd == KB_BR_NOOP);
    CHECK(next(&r, &cmd, &pl) && cmd == KB_U_BR_REPLY);
    memcpy(&u, pl, sizeof(u));
    CHECK(u.data_size == 4 && u.offsets_size == 0 && u.flags == 0x08);
    memcpy(&p, (const void *)(uintptr_t)u.buffer, 4);
    CHECK(p == status);
    p = u.buffer; reset(); wc(KB_U_BC_FREE_BUFFER, &p, 4); CHECK(call(0, &b) == 0); CHECK(live_bufs == 0 && bad_free == 0);
}

static void test_small_commands(void)
{
    kb_u_write_read b; kb_u_ptr_cookie pc = { 0xAABB0001u, 0xCCDD0002u }; kb_u_handle_cookie hc = { 3, 0x11223344u };
    uint32_t dd = 0x55667788u; struct { int32_t prio; uint32_t desc; } at = { 1, 2 };
    reset();
    wc(KB_U_BC_INCREFS_DONE, &pc, 8); wc(KB_U_BC_ACQUIRE_DONE, &pc, 8);
    wc(KB_U_BC_REQUEST_DEATH, &hc, 8); wc(KB_U_BC_CLEAR_DEATH, &hc, 8);
    wc(KB_U_BC_DEAD_DONE, &dd, 4); wc(KB_BC_ATTEMPT_ACQUIRE, &at, 8);
    wc(KB_BC_EXIT_LOOPER, NULL, 0);
    CHECK(call(0, &b) == 0 && b.write_consumed == wl && b.read_consumed == 0);
    CHECK(unknown_cmd == 0 && nlog == 6);
    CHECK(klog[0].cmd == BC_INCREFS_DONE && klog[0].a == 0xAABB0001ull && klog[0].b == 0xCCDD0002ull);
    CHECK(klog[1].cmd == BC_ACQUIRE_DONE && klog[1].a == 0xAABB0001ull);
    CHECK(klog[2].cmd == BC_REQUEST_DEATH_NOTIFICATION && klog[2].a == 3 && klog[2].b == 0x11223344ull);
    CHECK(klog[3].cmd == BC_CLEAR_DEATH_NOTIFICATION && klog[3].b == 0x11223344ull);
    CHECK(klog[4].cmd == BC_DEAD_BINDER_DONE && klog[4].a == 0x55667788ull);
    CHECK(klog[5].cmd == BC_ATTEMPT_ACQUIRE && klog[5].a == 1 && klog[5].b == 2);
}

static void test_read_commands(void)
{
    kb_u_write_read b; struct rd r; uint32_t cmd; const uint8_t *pl; int n = 0;
    struct binder_ptr_cookie pc = { 0x1234, 0x5678 }; struct binder_pri_ptr_cookie ppc = { 5, 0xA1, 0xB2 };
    uint64_t dead = 0xDEADBEEFull; int32_t err = -3;
    reset();
    qpush(BR_INCREFS, &pc, sizeof(pc)); qpush(BR_ACQUIRE, &pc, sizeof(pc)); qpush(BR_RELEASE, &pc, sizeof(pc));
    qpush(BR_DECREFS, &pc, sizeof(pc)); qpush(BR_ATTEMPT_ACQUIRE, &ppc, sizeof(ppc));
    qpush(BR_DEAD_BINDER, &dead, 8); qpush(BR_CLEAR_DEATH_NOTIFICATION_DONE, &dead, 8);
    qpush(BR_SPAWN_LOOPER, NULL, 0); qpush(BR_ERROR, &err, 4); qpush(BR_FAILED_REPLY, NULL, 0);
    qpush(BR_DEAD_REPLY, NULL, 0); qpush(BR_OK, NULL, 0);
    CHECK(call(512, &b) == 0);
    r.p = R; r.pos = 0; r.len = b.read_consumed;
    CHECK(next(&r, &cmd, &pl) && cmd == KB_BR_NOOP); n++;
    for (int i = 0; i < 4; i++) {
        kb_u_ptr_cookie q; static const uint32_t codes[4] = { KB_U_BR_INCREFS, KB_U_BR_ACQUIRE, KB_U_BR_RELEASE, KB_U_BR_DECREFS };
        CHECK(next(&r, &cmd, &pl) && cmd == codes[i]); memcpy(&q, pl, 8); CHECK(q.ptr == 0x1234 && q.cookie == 0x5678); n++;
    }
    { kb_u_pri_ptr_cookie q; CHECK(next(&r, &cmd, &pl) && cmd == KB_U_BR_ATTEMPT_ACQUIRE); memcpy(&q, pl, sizeof(q));
      CHECK(q.priority == 5 && q.ptr == 0xA1 && q.cookie == 0xB2); n++; }
    { uint32_t v; CHECK(next(&r, &cmd, &pl) && cmd == KB_U_BR_DEAD_BINDER); memcpy(&v, pl, 4); CHECK(v == 0xDEADBEEFu); n++; }
    { uint32_t v; CHECK(next(&r, &cmd, &pl) && cmd == KB_U_BR_CLEAR_DEATH_DONE); memcpy(&v, pl, 4); CHECK(v == 0xDEADBEEFu); n++; }
    CHECK(next(&r, &cmd, &pl) && cmd == KB_BR_SPAWN_LOOPER);
    { int32_t v; CHECK(next(&r, &cmd, &pl) && cmd == KB_BR_ERROR); memcpy(&v, pl, 4); CHECK(v == -3); }
    CHECK(next(&r, &cmd, &pl) && cmd == KB_BR_FAILED_REPLY);
    CHECK(next(&r, &cmd, &pl) && cmd == KB_BR_DEAD_REPLY);
    CHECK(next(&r, &cmd, &pl) && cmd == KB_BR_OK);
    CHECK(r.pos == r.len && n == 8);
}

static void test_partial_consumption(void)
{
    kb_u_write_read b; uint32_t h; kb_u_tr t; uint32_t blob[4] = { 1, 2, 3, 4 };
    uint32_t data_ptr; kb_u_tr u; struct rd rr; uint32_t cmd; const uint8_t *pl;
    kreset(); reset();
    for (h = 1; h <= 4; h++) wc(KB_BC_INCREFS, &h, 4);
    fail_at = 3;
    CHECK(call(0, &b) == -1 && errno == EFAULT);
    CHECK(b.write_consumed == 16 && nlog == 2);          /* two whole commands consumed */
    /* transaction first, failing command second: only the transaction is reported consumed */
    reset();
    memset(&t, 0, sizeof(t)); t.data_size = sizeof(blob); t.buffer = (uint32_t)(uintptr_t)blob;
    wc(KB_U_BC_TRANSACTION, &t, sizeof(t)); h = 1; wc(KB_BC_INCREFS, &h, 4);
    fail_at = 2;
    CHECK(call(128, &b) == -1 && b.write_consumed == 4 + sizeof(t) && b.read_consumed == 0);
    /* the transaction was queued by the driver: read it with an empty write */
    wl = 0; fail_at = 0; seen = 0;
    CHECK(call(128, &b) == 0);
    rr.p = R; rr.pos = 0; rr.len = b.read_consumed;
    data_ptr = 0;
    while (next(&rr, &cmd, &pl)) if (cmd == KB_U_BR_TRANSACTION) { memcpy(&u, pl, sizeof(u)); data_ptr = u.buffer; }
    CHECK(data_ptr != 0 && live_bufs == 1);
    reset(); h = 1; wc(KB_BC_INCREFS, &h, 4); wc(KB_U_BC_FREE_BUFFER, &data_ptr, 4);
    fail_at = 1;
    CHECK(call(0, &b) == -1 && b.write_consumed == 0 && live_bufs == 1);
    reset();   /* retry as libbinder would: block must still be intact */
    wc(KB_U_BC_FREE_BUFFER, &data_ptr, 4);
    CHECK(call(0, &b) == 0 && b.write_consumed == wl && live_bufs == 0 && bad_free == 0);
}

static void test_rejects_malformed(void)
{
    kb_u_write_read b; kb_u_tr t; uint8_t data[64]; uint32_t offs[2];
    memset(data, 0, sizeof(data));
    memset(&t, 0, sizeof(t)); t.data_size = sizeof(data); t.buffer = (uint32_t)(uintptr_t)data; t.offsets = (uint32_t)(uintptr_t)offs;
    put_obj(data, KB_TYPE_BINDER, 0, 1, 1); put_obj(data + 8, KB_TYPE_BINDER, 0, 1, 1);
    /* overlapping objects */
    reset(); offs[0] = 0; offs[1] = 8; t.offsets_size = 8; wc(KB_U_BC_TRANSACTION, &t, sizeof(t));
    CHECK(call(0, &b) == -1 && errno == EINVAL && kcalls == 0 && b.write_consumed == 0);
    /* object past the end */
    reset(); offs[0] = 56; t.offsets_size = 4; wc(KB_U_BC_TRANSACTION, &t, sizeof(t));
    CHECK(call(0, &b) == -1 && errno == EINVAL && kcalls == 0);
    /* offsets_size not a multiple of 4 */
    reset(); t.offsets_size = 6; wc(KB_U_BC_TRANSACTION, &t, sizeof(t));
    CHECK(call(0, &b) == -1 && errno == EINVAL && kcalls == 0);
    /* unknown object type */
    reset(); put_obj(data, 0x12345678u, 0, 0, 0); offs[0] = 0; t.offsets_size = 4; wc(KB_U_BC_TRANSACTION, &t, sizeof(t));
    CHECK(call(0, &b) == -1 && errno == EINVAL && kcalls == 0);
    /* unknown command */
    reset(); wc(0x40046399u, NULL, 0);
    CHECK(call(0, &b) == -1 && errno == EINVAL && kcalls == 0);
    /* truncated stream */
    reset(); wl = 2; CHECK(call(0, &b) == -1 && errno == EINVAL && kcalls == 0);
    /* non-zero consumed counters are not supported */
    reset(); { kb_u_write_read x; memset(&x, 0, sizeof(x)); x.write_consumed = 4;
      CHECK(kobo_binder_ioctl(3, KB_U_WRITE_READ, &x, fake_sys) == -1 && errno == EINVAL && kcalls == 0); }
}

static void test_many_objects(void)
{
    enum { N = 60 }; uint8_t data[N * 20]; uint32_t offs[N]; kb_u_tr t; kb_u_write_read b; struct rd r; uint32_t cmd, i;
    const uint8_t *pl; kb_u_tr u; reset();
    for (i = 0; i < N; i++) {
        uint32_t tag = 0xC0DE0000u + i; memcpy(data + i * 20, &tag, 4);
        put_obj(data + i * 20 + 4, i % 3 == 0 ? KB_TYPE_BINDER : i % 3 == 1 ? KB_TYPE_HANDLE : KB_TYPE_FD, i, 50 + i, 70 + i);
        offs[i] = i * 20 + 4;
    }
    memset(&t, 0, sizeof(t)); t.data_size = sizeof(data); t.offsets_size = sizeof(offs);
    t.buffer = (uint32_t)(uintptr_t)data; t.offsets = (uint32_t)(uintptr_t)offs; t.target = 1;
    wc(KB_U_BC_TRANSACTION, &t, sizeof(t));
    CHECK(call(256, &b) == 0 && bad_tx == 0);
    r.p = R; r.pos = 0; r.len = b.read_consumed;
    while (next(&r, &cmd, &pl)) if (cmd == KB_U_BR_TRANSACTION) {
        const uint8_t *d; const uint32_t *o;
        memcpy(&u, pl, sizeof(u)); d = (const uint8_t *)(uintptr_t)u.buffer; o = (const uint32_t *)(uintptr_t)u.offsets;
        CHECK(u.data_size == sizeof(data) && u.offsets_size == sizeof(offs));
        for (i = 0; i < N; i++) {
            uint32_t tag; kb_u_obj ob; memcpy(&tag, d + i * 20, 4); CHECK(tag == 0xC0DE0000u + i);
            CHECK(o[i] == offs[i]); memcpy(&ob, d + o[i], 16); CHECK(ob.flags == i);
            if (i % 3 == 0) CHECK(ob.type == KB_TYPE_HANDLE);
            if (i % 3 == 1) CHECK(ob.type == KB_TYPE_BINDER && ob.binder_or_handle == 0x1000 + 50 + i);
            if (i % 3 == 2) CHECK(ob.type == KB_TYPE_FD && ob.binder_or_handle == 150 + i);
        }
    }
    CHECK(live_bufs == 1);
    kreset(); reset(); { uint32_t p = u.buffer; wc(KB_U_BC_FREE_BUFFER, &p, 4); CHECK(call(0, &b) == 0 && live_bufs == 0); }
}

static void test_kernel_garbage(void)
{
    kb_u_write_read b; struct rd r; uint32_t cmd; const uint8_t *pl; struct binder_ptr_cookie big = { 0x100000000ull, 1 };
    int saw_failed = 0, saw_tr = 0;
    /* BR_REPLY the shim cannot translate: buffer is returned to the kernel, caller is woken */
    kreset(); reset(); inject_bad_tr();
    CHECK(live_bufs == 1);
    CHECK(call(256, &b) == 0 && live_bufs == 0 && bad_free == 0);
    r.p = R; r.pos = 0; r.len = b.read_consumed;
    while (next(&r, &cmd, &pl)) { if (cmd == KB_BR_FAILED_REPLY) saw_failed = 1; if (cmd == KB_U_BR_REPLY) saw_tr = 1; }
    CHECK(saw_failed && !saw_tr);
    /* a pointer that does not fit 32 bit is reported as an error, not truncated silently */
    reset(); qpush(BR_INCREFS, &big, sizeof(big));
    CHECK(call(128, &b) == -1 && errno == EOVERFLOW);
}

int main(void)
{
    long base = live_allocs;   /* libc start-up code may already have allocated */
    (void)dummy_unused;
    test_version(); test_transaction_roundtrip(); test_reply_status(); test_small_commands();
    test_read_commands(); test_partial_consumption(); test_rejects_malformed(); test_many_objects();
    test_kernel_garbage();
    CHECK(live_allocs == base);   /* every receive block and scratch buffer was released */
    if (fails) { fprintf(stderr, "%d check(s) failed\n", fails); return 1; }
    puts("binder shim tests passed");
    return 0;
}
