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
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
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

/* libnetutils-Einstiegspunkte (KitKat): per Preload ueberlagert, damit netd/NetworkUtils den Host
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
