/* SPDX-License-Identifier: MIT
 * Ersatz fuer den Android-Kernel-Logger (dev/log), den der Kobo-Kernel nicht hat und den es ohne
 * logd in Android KitKat/API 19 auch nicht gibt. libkobofb.so wird per LD_PRELOAD in jeden Prozess geladen und
 * ueberlagert die liblog-Einstiegspunkte; die Meldungen landen in KOBO_LOG_FILE (Standard
 * /data/local/tmp/android.log). Kein Android-Header noetig, Signaturen stehen hier. */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
#include "kobo_log.h"

/* ---- Laufzeit-Tuning ------------------------------------------------------------------------
 * Werte kommen aus der Umgebung (KOBO_LOG_LEVEL=...) oder aus /dev/kobo/tuning (Zeilen NAME=WERT),
 * das android.sh beim Start in den geteilten tmpfs schreibt. Dadurch wirken neue Werte auch bei einem
 * bereits installierten rootfs.img, dessen init.rc die Variablen nicht kennt. Einmal je Prozess gelesen. */
#ifndef __NR_openat
#define __NR_openat 322
#endif
#define KOBO_TUNING_FILE "/dev/kobo/tuning"
static int tuning_loaded;
static char tuning_buf[512];
static void tuning_load(void)
{
    ssize_t n; int fd, saved = errno;
    if (tuning_loaded) return;
    tuning_loaded = 1; tuning_buf[0] = 0;
    fd = (int)syscall(__NR_openat, AT_FDCWD, KOBO_TUNING_FILE, O_RDONLY | O_CLOEXEC, 0);
    if (fd >= 0) {
        n = read(fd, tuning_buf, sizeof(tuning_buf) - 2);
        if (n > 0) { tuning_buf[n] = '\n'; tuning_buf[n + 1] = 0; }
        else tuning_buf[0] = 0;
        syscall(__NR_close, fd);
    }
    errno = saved;
}
int kobo_tunable(const char *name, int fallback)
{
    const char *e = getenv(name), *p; size_t len = strlen(name);
    if (e && *e) return atoi(e);
    tuning_load();
    for (p = tuning_buf; *p; ) {
        if (!strncmp(p, name, len) && p[len] == '=') return atoi(p + len + 1);
        p = strchr(p, '\n'); if (!p) break; ++p;
    }
    return fallback;
}

/* Android-Prioritaeten: 2 V, 3 D, 4 I, 5 W, 6 E, 7 F. Standard: Info und hoeher (KOBO_LOG_LEVEL=3 fuer Debug).
 * Das Logfile bleibt als Dateideskriptor offen (O_APPEND ist atomar); frueher kostete jede Zeile
 * getenv + open + write + close, und in KitKat sind es beim Booten viele tausend Zeilen. */
static int log_fd = -1, log_level = -1, log_pid;
static void emit(int prio, const char *tag, const char *msg)
{
    static const char P[] = "??VDIWEF"; /* Prio 2..7 = V D I W E F */
    char buf[1024]; int n, saved = errno, pid = (int)getpid();
    if (log_level < 0) log_level = kobo_tunable("KOBO_LOG_LEVEL", 4);
    if (prio < log_level || prio < 3) { errno = saved; return; } /* Verbose nie */
    if (log_fd < 0 || log_pid != pid) {
        const char *path = getenv("KOBO_LOG_FILE");
        /* Nach fork() gehoert der geerbte Deskriptor dem Elternprozess: neu oeffnen. */
        if (log_fd >= 0 && log_pid != pid) syscall(__NR_close, log_fd);
        if (!path || !*path) path = "/data/local/tmp/android.log";
        log_fd = (int)syscall(__NR_openat, AT_FDCWD, path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0666);
        log_pid = pid;
        if (log_fd < 0) { errno = saved; return; }
    }
    n = snprintf(buf, sizeof(buf), "%c/%s(%d): %s", prio >= 0 && prio <= 7 ? P[prio] : '?',
                 tag ? tag : "?", pid, msg ? msg : "");
    if (n < 0) { errno = saved; return; }
    if ((size_t)n > sizeof(buf) - 2) n = (int)sizeof(buf) - 2;
    buf[n++] = '\n';
    if (write(log_fd, buf, (size_t)n) < 0) { /* ignore */ }
    errno = saved;
}

int __android_log_write(int prio, const char *tag, const char *text)
{ emit(prio, tag, text); return 1; }

int __android_log_buf_write(int bufid, int prio, const char *tag, const char *text)
{ (void)bufid; emit(prio, tag, text); return 1; }

int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap)
{ char b[800]; vsnprintf(b, sizeof(b), fmt, ap); emit(prio, tag, b); return 1; }

int __android_log_print(int prio, const char *tag, const char *fmt, ...)
{ va_list ap; char b[800]; va_start(ap, fmt); vsnprintf(b, sizeof(b), fmt, ap); va_end(ap); emit(prio, tag, b); return 1; }

int __android_log_buf_print(int bufid, int prio, const char *tag, const char *fmt, ...)
{ va_list ap; char b[800]; (void)bufid; va_start(ap, fmt); vsnprintf(b, sizeof(b), fmt, ap); va_end(ap); emit(prio, tag, b); return 1; }

void __android_log_assert(const char *cond, const char *tag, const char *fmt, ...)
{
    char b[800];
    if (fmt) { va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof(b), fmt, ap); va_end(ap); }
    else snprintf(b, sizeof(b), "Assertion failed: %s", cond ? cond : "?");
    emit(7, tag, b);
    abort();
}
