/* SPDX-License-Identifier: MIT
 * Container entry point. Never runs Android init in the host PID namespace.
 * All host-visible mounts are prepared by android.sh beneath its own run/.
 */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#ifndef CLONE_NEWNS
#define CLONE_NEWNS 0x00020000
#endif
#ifndef CLONE_NEWPID
#define CLONE_NEWPID 0x20000000
#endif
/* API-21's sys/mount.h omits the mount-propagation flags, although the
 * kernel ABI supports them. MS_PRIVATE is (1 << 18) in Linux mount.h. */
#ifndef MS_PRIVATE
#define MS_PRIVATE (1 << 18)
#endif
static volatile sig_atomic_t child_pid;
static int unsafe_no_namespaces(void) {
    const char *value = getenv("KOBO_ALLOW_UNSAFE_NO_NAMESPACES");
    return value && !strcmp(value, "1");
}
static void terminate_child(int sig) {
    (void)sig;
    /* PID 1 may ignore TERM. Kill only our private namespace init; the kernel
     * tears down its descendants. android.sh stops writers and syncs first. */
    if (child_pid > 0) kill((pid_t)child_pid, SIGKILL);
}
static void die(const char *what) { perror(what); exit(1); }
static void mount_proc(const char *path, int unsafe) {
    int saved;
    struct stat st;
    {
        char parent[PATH_MAX], a[128], b[128];
        struct stat sp, sq;
        ssize_t n;
        if ((n = readlink("/proc/self/ns/mnt", a, sizeof a - 1)) > 0) a[n] = 0; else strcpy(a, "?");
        if ((n = readlink("/proc/self/ns/pid", b, sizeof b - 1)) > 0) b[n] = 0; else strcpy(b, "?");
        fprintf(stderr, "container ns: mnt=%s pid=%s pid=%d\n", a, b, (int)getpid());
        if (snprintf(parent, sizeof parent, "%s/..", path) < (int)sizeof parent &&
            !stat(path, &sp) && !stat(parent, &sq) && sp.st_dev != sq.st_dev) {
            fputs("proc bereits gemountet (Mountpoint erkannt)\n", stderr);
            return;
        }
    }
    /* Do not trust a bare mkdir(): create every missing parent and accept an
     * existing directory. Report the exact path so failures are diagnosable. */
    if (stat(path, &st) < 0 || !S_ISDIR(st.st_mode)) {
        char tmp[PATH_MAX], *q;
        if (snprintf(tmp, sizeof tmp, "%s", path) >= (int)sizeof tmp) die("proc path too long");
        for (q = tmp + 1; *q; ++q) {
            if (*q != '/') continue;
            *q = 0;
            if (mkdir(tmp, 0755) < 0 && errno != EEXIST) { fprintf(stderr, "mkdir %s: %s\n", tmp, strerror(errno)); exit(1); }
            *q = '/';
        }
        if (mkdir(tmp, 0755) < 0 && errno != EEXIST) { fprintf(stderr, "mkdir %s: %s\n", tmp, strerror(errno)); exit(1); }
    }
    {
        struct { const char *name; int kind; unsigned long flags; } tries[] = {
            { "proc nosuid,nodev,noexec", 0, MS_NOSUID | MS_NODEV | MS_NOEXEC },
            { "proc flags=0", 0, 0 },
            { "proc nosuid", 0, MS_NOSUID },
            { "bind /proc", 1, MS_BIND },
            { "bind /proc rec", 1, MS_BIND | MS_REC },
        };
        size_t i;
        saved = 0;
        for (i = 0; i < sizeof tries / sizeof *tries; ++i) {
            int r;
            if (tries[i].kind && !unsafe) continue;
            r = tries[i].kind ? mount("/proc", path, NULL, tries[i].flags, NULL)
                              : mount("proc", path, "proc", tries[i].flags, NULL);
            if (!r) {
                if (tries[i].kind) fputs("WARNING: private proc mount unavailable; using host /proc in unsafe fallback\n", stderr);
                return;
            }
            fprintf(stderr, "proc mount (%s) at %s failed: %s\n", tries[i].name, path, strerror(errno));
            if (!saved) saved = errno;
        }
    }
    errno = saved; die("private proc mount");
}
static int isolated(const char *root, int check) {
    pid_t p;
    int status;
    int unsafe = unsafe_no_namespaces();
    if (!check) fputs("kobo-container: proc-mount fallback build 2026-11-02e\n", stderr);
    if (syscall(__NR_unshare, CLONE_NEWNS | CLONE_NEWPID) < 0) {
        if (!unsafe) die("unshare: kernel needs CONFIG_NAMESPACES, CONFIG_PID_NS and CONFIG_MNT_NS");
        fputs("WARNING: starting without mount/PID namespace isolation\n", stderr);
    } else if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0) {
        die("make mounts private");
    }
    p = fork();
    if (p < 0) die("fork PID namespace");
    if (!p) {
        char proc[PATH_MAX];
        if (!unsafe && getpid() != 1) { fputs("Refusing to run init outside a private PID namespace\n", stderr); _exit(1); }
        if (check) _exit(0);
        if (snprintf(proc, sizeof proc, "%s/proc", root) >= (int)sizeof proc) _exit(1);
        mount_proc(proc, unsafe);
        if (chdir(root) || chroot(".") || chdir("/")) die("chroot");
        if (access("/kobo-chroot", F_OK)) die("rootfs lacks kobo-chroot marker");
        /* No host environment, no inherited LD_PRELOAD or library paths. */
        {
            char *const argv[] = { "/init", NULL };
            char *const env[] = { "PATH=/sbin:/system/bin:/system/xbin", "ANDROID_ROOT=/system", "ANDROID_DATA=/data", NULL };
            execve("/init", argv, env);
        }
        die("exec Android init");
    }
    child_pid = p;
    signal(SIGTERM, terminate_child);
    signal(SIGINT, terminate_child);
    while (waitpid(p, &status, 0) < 0) {
        if (errno != EINTR) die("waitpid");
    }
    child_pid = 0;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
int main(int argc, char **argv) {
    char resolved[PATH_MAX];
    const char *root = NULL;
    int check = 0, i;
    if (geteuid()) { fputs("kobo-container requires root\n", stderr); return 1; }
    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--check")) check = 1;
        else if (!strcmp(argv[i], "--root") && i + 1 < argc) root = argv[++i];
        else { fputs("Usage: kobo-container --check | --root ROOTFS\n", stderr); return 2; }
    }
    if (!check) {
        if (!root || !realpath(root, resolved) || !strcmp(resolved, "/")) {
            fputs("Invalid rootfs path\n", stderr); return 2;
        }
        root = resolved;
    }
    return isolated(root, check);
}
