/* SPDX-License-Identifier: MIT */
/*
 * Ersatz fuer /sbin/healthd (KitKat/API 19).
 *
 * Das Original ist STATISCH gelinkt (LOCAL_FORCE_STATIC_EXECUTABLE). LD_PRELOAD
 * wirkt dort nicht, also greift die Binder-32->64-Bit-Uebersetzung aus
 * libkobofb.so nicht: BINDER_VERSION/BINDER_WRITE_READ scheitern am Kobo-Kernel
 * (Protokoll 8), healthd bricht ab, "batteryproperties" wird nie registriert,
 * BatteryService.<init> wirft NullPointerException, system_server stirbt und
 * zygote startet endlos neu. Der QEMU-Kernel ist mit CONFIG_ANDROID_BINDER_IPC_32BIT
 * gebaut und kennt das Problem nicht.
 *
 * Dieses Programm ist dynamisch (bionic) gelinkt, laeuft unter LD_PRELOAD und
 * registriert den Dienst "batteryproperties". Es meldet einen festen Akkustand
 * (Netzteil, 100 %), da kein Android-Akku-Sysfs durchgereicht wird.
 */
#include <stdint.h>
#include <string.h>
#include "kobo_binder_abi.h"

#define KH_STRICT_GATHER 0x100u
#define KH_ADD_SERVICE 3u
#define KH_FIRST_CALL 1u
#define KH_TF_ONE_WAY 1u
#define KH_REG_DESC "android.os.IBatteryPropertiesRegistrar"
#define KH_LST_DESC "android.os.IBatteryPropertiesListener"
#define KH_SM_DESC "android.os.IServiceManager"

struct kh_buf { uint8_t *p; size_t cap, len; int overflow; };

static void kh_put(struct kh_buf *b, const void *d, size_t n)
{
    if (b->len + n > b->cap) { b->overflow = 1; return; }
    memcpy(b->p + b->len, d, n); b->len += n;
}
static void kh_pad(struct kh_buf *b) { static const uint8_t z[4]; if (b->len & 3u) kh_put(b, z, 4u - (b->len & 3u)); }
static void kh_i32(struct kh_buf *b, uint32_t v) { kh_put(b, &v, 4); }
/* Parcel::writeString16: int32 Zeichenzahl, UTF-16LE, 0-Terminator, auf 4 Byte aufgefuellt (nur ASCII). */
static void kh_str16(struct kh_buf *b, const char *s)
{
    size_t n = strlen(s), i;
    kh_i32(b, (uint32_t)n);
    for (i = 0; i < n; i++) { uint16_t c = (uint8_t)s[i]; kh_put(b, &c, 2); }
    { uint16_t z = 0; kh_put(b, &z, 2); }
    kh_pad(b);
}
static void kh_token(struct kh_buf *b, const char *desc) { kh_i32(b, KH_STRICT_GATHER); kh_str16(b, desc); }

/* IServiceManager.addService(name, binder, allowIsolated); Objektoffset -> *off */
size_t kh_build_add_service(struct kh_buf *b, const char *name, uint32_t local, uint32_t *off)
{
    kb_u_obj o;
    kh_token(b, KH_SM_DESC); kh_str16(b, name);
    *off = (uint32_t)b->len;
    o.type = KB_TYPE_BINDER; o.flags = 0x7f; o.binder_or_handle = local; o.cookie = local;
    kh_put(b, &o, sizeof o);
    kh_i32(b, 0);
    return b->len;
}
/* IBatteryPropertiesListener.batteryPropertiesChanged(BatteryProperties) */
size_t kh_build_props(struct kh_buf *b)
{
    kh_token(b, KH_LST_DESC);
    kh_i32(b, 1);                 /* Parcelable nicht null */
    kh_i32(b, 1); kh_i32(b, 0); kh_i32(b, 0);   /* AC online, USB, Wireless */
    kh_i32(b, 5);                 /* BATTERY_STATUS_FULL */
    kh_i32(b, 2);                 /* BATTERY_HEALTH_GOOD */
    kh_i32(b, 1);                 /* present */
    kh_i32(b, 100);               /* Level */
    kh_i32(b, 4200);              /* mV */
    kh_i32(b, 0);                 /* batteryCurrentNow (KitKat 4.4.x: Pflichtfeld vor Temperatur!) */
    kh_i32(b, 0);                 /* batteryChargeCounter (ebenso) */
    kh_i32(b, 250);               /* 0.1 Grad C */
    kh_str16(b, "Li-ion");
    return b->len;
}
/* Prueft Token + Code einer eingehenden Transaktion; liefert Offset hinter dem Token oder 0. */
size_t kh_parse_token(const uint8_t *d, size_t n, const char *desc)
{
    uint32_t len; size_t need = strlen(desc), i;
    if (n < 8) return 0;
    memcpy(&len, d + 4, 4);
    if (len != need || n < 8 + 2 * need + 2) return 0;
    for (i = 0; i < need; i++) { uint16_t c; memcpy(&c, d + 8 + 2 * i, 2); if (c != (uint8_t)desc[i]) return 0; }
    return (8 + 2 * need + 2 + 3) & ~(size_t)3;
}

#ifndef KOBO_HEALTHD_TEST
#if UINTPTR_MAX != 0xffffffffu
#error "kobo-healthd muss als 32-Bit-Bionic-Programm (NDK, ARMv7) gebaut werden"
#endif
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static int fd = -1;
static uint32_t local_token = 0x4b48u;   /* beliebiger, von 0 verschiedener Zeiger-Wert */
static uint32_t listener[8]; static int nlistener;

static void logmsg(const char *m)
{
    char line[200]; struct timespec ts; int l, k;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    k = snprintf(line, sizeof line, "[%5ld.%03ld] %s\n", (long)ts.tv_sec, ts.tv_nsec / 1000000, m);
    if (k <= 0) return;
    if (k >= (int)sizeof line) k = (int)sizeof line - 1;
    l = open("/data/local/tmp/kobo-healthd.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
    if (l >= 0) { if (write(l, line, (size_t)k) < 0) { /* ignore */ } close(l); }
    l = open("/dev/kmsg", O_WRONLY);
    if (l >= 0) { char km[220]; int n = snprintf(km, sizeof km, "<6>kobo-healthd: %s\n", m); if (n > 0 && write(l, km, (size_t)n) < 0) { /* ignore */ } close(l); }
}
static void klog(const char *fmt, int a, int b)
{
    char m[120]; snprintf(m, sizeof m, fmt, a, b); logmsg(m);
}
static int bwr(const void *w, size_t wl, void *r, size_t rl, size_t *rc)
{
    kb_u_write_read x;
    x.write_size = (uint32_t)wl; x.write_consumed = 0; x.write_buffer = (uint32_t)(uintptr_t)w;
    x.read_size = (uint32_t)rl; x.read_consumed = 0; x.read_buffer = (uint32_t)(uintptr_t)r;
    if (ioctl(fd, (int)KB_U_WRITE_READ, &x) < 0) return -1;
    if (rc) *rc = x.read_consumed;
    return 0;
}
static void put_cmd(struct kh_buf *w, uint32_t cmd, const void *d, size_t n) { kh_put(w, &cmd, 4); if (n) kh_put(w, d, n); }
static void put_tr(struct kh_buf *w, uint32_t cmd, uint32_t target, uint32_t code, uint32_t flags,
                   const uint8_t *data, size_t dn, const uint32_t *offs, size_t no)
{
    kb_u_tr t; memset(&t, 0, sizeof t);
    t.target = target; t.code = code; t.flags = flags;
    t.data_size = (uint32_t)dn; t.offsets_size = (uint32_t)(4 * no);
    t.buffer = (uint32_t)(uintptr_t)data; t.offsets = (uint32_t)(uintptr_t)offs;
    put_cmd(w, cmd, &t, sizeof t);
}
static void reply_ok(struct kh_buf *w)
{
    static uint32_t zero;   /* Parcel mit int32 0 = "keine Exception" / Status 0 */
    put_tr(w, KB_U_BC_REPLY, 0, 0, 0, (const uint8_t *)&zero, 4, NULL, 0);
}
static void send_props(uint32_t handle, struct kh_buf *w)
{
    static uint8_t pb[256]; struct kh_buf b; b.p = pb; b.cap = sizeof pb; b.len = 0; b.overflow = 0;
    kh_build_props(&b);
    if (!b.overflow) put_tr(w, KB_U_BC_TRANSACTION, handle, KH_FIRST_CALL, KH_TF_ONE_WAY, pb, b.len, NULL, 0);
}
/* BR_INCREFS/BR_ACQUIRE fuer unseren Knoten muessen mit *_DONE quittiert werden, sonst bleibt der Knoten im Kernel "pending". */
static void ack_ref(uint32_t cmd, const uint8_t *src, struct kh_buf *w)
{
    kb_u_ptr_cookie pc; memcpy(&pc, src, sizeof pc);
    put_cmd(w, cmd == KB_U_BR_INCREFS ? KB_U_BC_INCREFS_DONE : KB_U_BC_ACQUIRE_DONE, &pc, sizeof pc);
}
static int add_service(const char *svc)
{
    uint8_t pb[256], wb[256], rb[512], ab[64]; struct kh_buf p, w, a; uint32_t off; size_t rc, pos;
    p.p = pb; p.cap = sizeof pb; p.len = 0; p.overflow = 0;
    kh_build_add_service(&p, svc, local_token, &off);
    w.p = wb; w.cap = sizeof wb; w.len = 0; w.overflow = 0;
    put_cmd(&w, KB_BC_ENTER_LOOPER, NULL, 0);
    put_tr(&w, KB_U_BC_TRANSACTION, 0, KH_ADD_SERVICE, 0, pb, p.len, &off, 1);
    if (p.overflow || w.overflow) return -1;
    if (bwr(wb, w.len, rb, sizeof rb, &rc) < 0) { klog("addService: ioctl errno=%d (%d)", errno, 0); return -1; }
    for (;;) {
        a.p = ab; a.cap = sizeof ab; a.len = 0; a.overflow = 0;
        for (pos = 0; pos + 4 <= rc;) {
            uint32_t cmd; memcpy(&cmd, rb + pos, 4); pos += 4;
            if (cmd == KB_U_BR_REPLY) {
                kb_u_tr t; uint32_t status = 1, fr = KB_U_BC_FREE_BUFFER;
                struct kh_buf f; uint8_t fb[16];
                memcpy(&t, rb + pos, sizeof t);
                if (t.data_size >= 4) memcpy(&status, (const void *)(uintptr_t)t.buffer, 4);
                f.p = fb; f.cap = sizeof fb; f.len = 0; f.overflow = 0;
                put_cmd(&f, fr, &t.buffer, 4);
                if (a.len) bwr(ab, a.len, NULL, 0, NULL);
                bwr(fb, f.len, NULL, 0, NULL);
                klog("addService: reply status=%d size=%d", (int)status, (int)t.data_size);
                return status == 0 ? 0 : -1;
            }
            if (cmd == KB_BR_DEAD_REPLY || cmd == KB_BR_FAILED_REPLY) { klog("addService: dead/failed reply 0x%x (%d)", (int)cmd, 0); return -1; }
            if (cmd == KB_BR_ERROR) pos += 4;
            else if (cmd == KB_U_BR_INCREFS || cmd == KB_U_BR_ACQUIRE) { ack_ref(cmd, rb + pos, &a); pos += 8; }
            else if (cmd == KB_U_BR_RELEASE || cmd == KB_U_BR_DECREFS) pos += 8;
            else if (cmd == KB_U_BR_TRANSACTION) pos += sizeof(kb_u_tr);
        }
        if (a.len && !a.overflow) bwr(ab, a.len, NULL, 0, NULL);
        if (bwr(NULL, 0, rb, sizeof rb, &rc) < 0) { klog("addService: read errno=%d (%d)", errno, 0); return -1; }
    }
}
static void serve(void)
{
    uint8_t rb[1024], wb[512]; size_t rc, pos; struct kh_buf w;
    for (;;) {
        w.p = wb; w.cap = sizeof wb; w.len = 0; w.overflow = 0; rc = 0;
        if (bwr(NULL, 0, rb, sizeof rb, &rc) < 0) { logmsg("read failed"); return; }
        for (pos = 0; pos + 4 <= rc;) {
            uint32_t cmd; memcpy(&cmd, rb + pos, 4); pos += 4;
            if (cmd == KB_U_BR_INCREFS || cmd == KB_U_BR_ACQUIRE) {
                kb_u_ptr_cookie pc; memcpy(&pc, rb + pos, sizeof pc); pos += sizeof pc;
                put_cmd(&w, cmd == KB_U_BR_INCREFS ? KB_U_BC_INCREFS_DONE : KB_U_BC_ACQUIRE_DONE, &pc, sizeof pc);
            } else if (cmd == KB_U_BR_RELEASE || cmd == KB_U_BR_DECREFS) pos += sizeof(kb_u_ptr_cookie);
            else if (cmd == KB_BR_ERROR || cmd == KB_U_BR_DEAD_BINDER || cmd == KB_U_BR_CLEAR_DEATH_DONE || cmd == KB_BR_ACQUIRE_RESULT) pos += 4;
            else if (cmd == KB_U_BR_ATTEMPT_ACQUIRE) pos += sizeof(kb_u_pri_ptr_cookie);
            else if (cmd == KB_U_BR_REPLY) pos += sizeof(kb_u_tr);
            else if (cmd == KB_U_BR_TRANSACTION) {
                kb_u_tr t; const uint8_t *d; size_t at; uint32_t fr = KB_U_BC_FREE_BUFFER;
                memcpy(&t, rb + pos, sizeof t); pos += sizeof t;
                d = (const uint8_t *)(uintptr_t)t.buffer;
                at = kh_parse_token(d, t.data_size, KH_REG_DESC);
                if (at && t.code == KH_FIRST_CALL && t.offsets_size >= 4 && t.data_size >= at + sizeof(kb_u_obj)) {
                    kb_u_obj o; memcpy(&o, d + at, sizeof o);
                    if (o.type == KB_TYPE_HANDLE && nlistener < 8) {
                        uint32_t h = o.binder_or_handle;
                        listener[nlistener++] = h;
                        put_cmd(&w, KB_BC_INCREFS, &h, 4);
                        put_cmd(&w, KB_BC_ACQUIRE, &h, 4);
                        if (!(t.flags & KH_TF_ONE_WAY)) reply_ok(&w);
                        put_cmd(&w, fr, &t.buffer, 4);
                        send_props(h, &w);
                        logmsg("listener registered");
                        continue;
                    }
                }
                if (!(t.flags & KH_TF_ONE_WAY)) reply_ok(&w);
                put_cmd(&w, fr, &t.buffer, 4);
            }
            /* NOOP, TRANSACTION_COMPLETE, SPAWN_LOOPER, OK, DEAD_REPLY, FAILED_REPLY: keine Nutzlast */
        }
        if (w.len && !w.overflow) bwr(wb, w.len, NULL, 0, NULL);
    }
}
int main(void)
{
    int tries; uint32_t ver = 0; void *map;
    for (tries = 0; tries < 600; tries++) {
        fd = open("/dev/binder", O_RDWR);
        if (fd >= 0) break;
        sleep(1);
    }
    if (fd < 0) { logmsg("open /dev/binder failed"); return 1; }
    if (ioctl(fd, (int)KB_VERSION, &ver) < 0 || ver != KB_PROTOCOL_USER) { klog("binder version %d (erwartet %d): LD_PRELOAD fehlt?", (int)ver, (int)KB_PROTOCOL_USER); return 1; }
    map = mmap(NULL, 128 * 1024, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) { logmsg("mmap failed"); return 1; }
    /* KitKat (4.4.x) BatteryService sucht "batterypropreg"; "batteryproperties" gilt erst ab Android 5.
     * Beide Namen auf denselben Knoten registrieren. */
    {
        static const char *const names[2] = { "batterypropreg", "batteryproperties" };
        int i;
        for (i = 0; i < 2; i++) {
            for (tries = 0; tries < 600; tries++) {   /* servicemanager darf spaeter starten */
                if (add_service(names[i]) == 0) break;
                klog("addService attempt %d failed (%d)", tries + 1, 0);
                { struct timespec ts = { 1, 0 }; nanosleep(&ts, NULL); }
            }
            if (tries >= 600) { logmsg("addService failed"); return 1; }
        }
    }
    logmsg("batterypropreg + batteryproperties registered");
    /* init.rc startet class main (zygote, surfaceflinger, ...) erst jetzt: system_server braucht den Dienst sofort. */
    if (system("/system/bin/setprop kobo.healthd.ready 1") != 0) logmsg("setprop kobo.healthd.ready failed");
    serve();
    return 1;
}
#endif
