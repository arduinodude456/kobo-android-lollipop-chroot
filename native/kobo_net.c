/* SPDX-License-Identifier: MIT */
/*
 * Schutz des Host-Netzwerks. Android (netd, system_server) teilt den Netzwerk-Namespace mit dem
 * Kobo. Wenn WifiStateMachine/ConnectivityService "ihre" Schnittstelle aufraeumen (Adressen
 * loeschen, Default-Route entfernen, Schnittstelle herunterfahren), wuerde das das echte WLAN des
 * Kobo kappen. libkobofb.so wird per LD_PRELOAD in jeden Android-Prozess geladen und macht diese
 * Schreibzugriffe zu No-Ops (Erfolg wird vorgetäuscht). Lesen und "lo" bleiben unberuehrt.
 */
#pragma GCC diagnostic ignored "-Wunused-parameter"
#include "kobo_net.h"
#include <fcntl.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdint.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef SYS_openat
#ifdef __NR_openat
#define SYS_openat __NR_openat
#endif
#endif

static void guard_log(const char *what)
{
    static int lines;
    char buf[160]; int n, fd;
    if (lines > 200) return;
    lines++;
    n = snprintf(buf, sizeof buf, "blockiert: %s\n", what);
    if (n <= 0) return;
    fd = (int)syscall(SYS_openat, AT_FDCWD, "/data/local/tmp/kobo-net-guard.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
    if (fd >= 0) { if (write(fd, buf, (size_t)n) < 0) { /* ignorieren */ } close(fd); }
}

int kobo_net_blocks(unsigned long request, const void *arg)
{
    const struct ifreq *ifr = arg;
    switch (request) {
    case SIOCADDRT: case SIOCDELRT: case 0x8939:
        guard_log("Routen-ioctl");
        return 1;
    case SIOCSIFADDR: case SIOCSIFDSTADDR: case SIOCSIFBRDADDR: case SIOCSIFNETMASK:
    case SIOCSIFMTU: case SIOCSIFHWADDR: case SIOCSIFMETRIC: case SIOCSIFTXQLEN:
    case SIOCSIFNAME:
        if (ifr && !strncmp(ifr->ifr_name, "lo", IFNAMSIZ)) return 0;
        guard_log(ifr ? ifr->ifr_name : "?");
        return 1;
    case SIOCSIFFLAGS:
        if (!ifr || !strncmp(ifr->ifr_name, "lo", IFNAMSIZ)) return 0;
        if (ifr->ifr_flags & IFF_UP) return 0;          /* hochfahren ist harmlos */
        guard_log("Schnittstelle herunterfahren");
        return 1;
    default:
        return 0;
    }
}

int kobo_net_hides_path(const char *path, int flags)
{
    if (!path || strncmp(path, "/proc/sys/net/", 14)) return 0;
    return (flags & O_ACCMODE) != O_RDONLY;
}

/* libnetutils-Einstiegspunkte (Lollipop): per Preload ueberlagert, damit netd/NetworkUtils den Host
 * nicht veraendern. Rueckgabe 0 = Erfolg. */
#define NOOP(sig, label) int sig { guard_log(label); return 0; }
NOOP(ifc_clear_addresses(const char *name), "ifc_clear_addresses")
NOOP(ifc_down(const char *name), "ifc_down")
NOOP(ifc_disable(const char *name), "ifc_disable")
NOOP(ifc_set_addr(const char *name, uint32_t addr), "ifc_set_addr")
NOOP(ifc_set_prefixLength(const char *name, int prefix), "ifc_set_prefixLength")
NOOP(ifc_add_address(const char *name, const char *address, int prefixlen), "ifc_add_address")
NOOP(ifc_del_address(const char *name, const char *address, int prefixlen), "ifc_del_address")
NOOP(ifc_configure(const char *name, uint32_t a, unsigned p, uint32_t g, uint32_t d1, uint32_t d2), "ifc_configure")
NOOP(ifc_create_default_route(const char *name, uint32_t gw), "ifc_create_default_route")
NOOP(ifc_add_route(const char *name, const char *dst, int prefix, const char *gw), "ifc_add_route")
NOOP(ifc_remove_route(const char *name, const char *dst, int prefix, const char *gw), "ifc_remove_route")
NOOP(ifc_remove_default_route(const char *name), "ifc_remove_default_route")
NOOP(ifc_remove_host_routes(const char *name), "ifc_remove_host_routes")
NOOP(ifc_reset_connections(const char *name, const int mask), "ifc_reset_connections")

/*
 * KOBO_WIFICONNECT_V1: Lollipops wpa_ctrl_open() verbindet auf "/dev/socket/wpa_<iface>" und meldet bei
 * Fehlschlag nur "Unable to open connection to supplicant ... <errno>". Schlaegt der Verbindungsaufbau zur
 * Supplicant-Attrappe einmal fehl (Socket noch nicht/nicht mehr da, anderer Pfad), bleibt WifiStateMachine
 * dauerhaft haengen. Deshalb: bei Fehlschlag den genauen errno protokollieren, kurz wiederholen und die
 * gleichwertigen Pfade der Attrappe (/dev/socket/<iface>, /data/misc/wifi/sockets/<iface>) probieren.
 * Alle anderen connect()-Aufrufe laufen unveraendert durch.
 */
#ifndef KOBO_NR_CONNECT
#ifdef __NR_connect
#define KOBO_NR_CONNECT __NR_connect
#else
#define KOBO_NR_CONNECT SYS_connect
#endif
#endif

static void wifi_note(const char *path, int err, int tries)
{
    static int lines;
    char buf[240]; int n, fd;
    if (lines > 120) return;
    lines++;
    n = snprintf(buf, sizeof buf, "wpa-connect %s: errno=%d (%s) nach %d Versuchen\n", path, err, strerror(err), tries);
    if (n <= 0) return;
    fd = (int)syscall(SYS_openat, AT_FDCWD, "/data/local/tmp/kobo-net-guard.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
    if (fd >= 0) { if (write(fd, buf, (size_t)n) < 0) { /* ignorieren */ } close(fd); }
}

static int wifi_try(int fd, const char *path)
{
    struct sockaddr_un a;
    size_t l = strlen(path);
    if (l >= sizeof a.sun_path) { errno = ENAMETOOLONG; return -1; }
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    memcpy(a.sun_path, path, l);
    return (int)syscall(KOBO_NR_CONNECT, fd, (struct sockaddr *)&a, (socklen_t)sizeof a);
}

int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    const struct sockaddr_un *u = (const struct sockaddr_un *)addr;
    char path[110], alt[160];
    int r, e, i;
    r = (int)syscall(KOBO_NR_CONNECT, fd, addr, len);
    if (r == 0 || !addr || len <= (socklen_t)sizeof(sa_family_t) || addr->sa_family != AF_UNIX) return r;
    if (strncmp(u->sun_path, "/dev/socket/wpa_", 16) != 0) return r;
    e = errno;
    memset(path, 0, sizeof path);
    memcpy(path, u->sun_path, sizeof path - 1 < sizeof u->sun_path ? sizeof path - 1 : sizeof u->sun_path);
    for (i = 0; i < 30; i++) {
        if (i) usleep(100000);
        if (wifi_try(fd, path) == 0) { if (i) wifi_note(path, e, i + 1); errno = 0; return 0; }
        e = errno;
        snprintf(alt, sizeof alt, "/dev/socket/%s", path + 16);
        if (wifi_try(fd, alt) == 0) { wifi_note(alt, e, i + 1); errno = 0; return 0; }
        snprintf(alt, sizeof alt, "/data/misc/wifi/sockets/%s", path + 16);
        if (wifi_try(fd, alt) == 0) { wifi_note(alt, e, i + 1); errno = 0; return 0; }
    }
    wifi_note(path, e, i);
    errno = e;
    return -1;
}
