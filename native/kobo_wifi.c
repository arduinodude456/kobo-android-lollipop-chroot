/* SPDX-License-Identifier: MIT */
/*
 * kobo-wpa: bringt das WLAN des Kobo-Hosts in Androids Wi-Fi-Stack.
 *
 * Android laeuft als Chroot im Netzwerk-Namespace des Kobo: Sockets, Routen und DNS-Server des
 * Hosts sind fuer Android bereits nutzbar. Es fehlt nur, dass Androids ConnectivityService ein
 * "verbundenes" Netz sieht; ohne das melden Browser, DownloadProvider und viele Apps "keine
 * Verbindung". KitKat bekommt seinen Wi-Fi-Zustand von WifiStateMachine, und die spricht mit
 * wpa_supplicant (Kontrollsocket /data/misc/wifi/sockets/<iface>) und dhcpcd. Beide ersetzt
 * dieses Programm durch schlanke Spiegel des Host-Zustands:
 *
 *   kobo-wpa --supplicant IFACE   wpa_supplicant-Attrappe (wpa_ctrl-Protokoll, Datagramm-Socket)
 *   kobo-wpa --dhcp IFACE         dhcpcd-Attrappe: liest IP/Gateway/DNS des Hosts und setzt die
 *                                 Properties dhcp.<iface>.*, die libnetutils erwartet
 *   kobo-wpa --ipinfo IFACE       Diagnose: gibt die erkannten Host-Daten aus
 *   kobo-wpa --probe IFACE        Diagnose: oeffnet den Kontrollsocket wie system_server (uid 1000)
 *
 * Der Host (KOReader/Nickel) bleibt allein zustaendig fuer Verbinden, Passwort und Roaming.
 * Dieses Programm veraendert nie Adressen, Routen oder Schnittstellen.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define KW_MAX_MON 8
#define KW_MAX_SOCK 4
#define KW_MAX_EV 12
#define KW_AID_WIFI 1010
#define KW_FAKE_BSSID "02:4b:6f:00:00:01"
#define KW_FREQ 2437
#define KW_RSSI (-45)

enum { EV_SYNC = 1, EV_DISC, EV_SCAN };

struct kw_link {
    int up;                    /* IFF_UP und IPv4-Adresse vorhanden */
    uint32_t ip, mask, gw;     /* Netzwerk-Bytefolge (wie in_addr) */
    char mac[18];
};

struct kw_mon { struct sockaddr_un addr; socklen_t len; int used; int sock; };
struct kw_ev { long long due; int kind; };

struct kw {
    char iface[IFNAMSIZ];
    char dir[160];
    char envfile[160];
    char ssid[96];             /* Rohtext des Hosts */
    int link_up;
    int visible;               /* Android wurde "verbunden" gemeldet */
    int user_off;              /* Android hat DISCONNECT gesendet */
    int next_net;
    int quit;
    struct kw_link link;
    struct kw_mon mon[KW_MAX_MON];
    struct kw_ev ev[KW_MAX_EV];
    int socks[KW_MAX_SOCK];    /* ein Socket je Pfad, unter dem Android den Supplicant suchen koennte */
    char paths[KW_MAX_SOCK][220];
    int nsock;
    int nev;
    long long last_sync;
};

/* ------------------------------------------------------------------ Hilfsfunktionen */

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int g_log_lines;
static void kw_log(const char *fmt, ...)
{
    const char *path = getenv("KOBO_WPA_LOG");
    char buf[512], line[640];
    va_list ap;
    int n, fd;
    if (!path || !*path) path = "/data/local/tmp/kobo-wpa.log";
    if (g_log_lines > 4000) return;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    n = snprintf(line, sizeof line, "%lld %s\n", now_ms() / 1000, buf);
    if (n <= 0) return;
    fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0666);
    if (fd >= 0) { if (write(fd, line, (size_t)n) < 0) { /* ignorieren */ } close(fd); }
    g_log_lines++;
}

static void kw_ip_str(uint32_t ip, char *out, size_t cap)
{
    struct in_addr a;
    a.s_addr = ip;
    snprintf(out, cap, "%s", inet_ntoa(a));
}

/* Liest KEY=Wert aus der vom Starter geschriebenen Host-Datei. */
static int kw_env_get(const char *path, const char *key, char *out, size_t cap)
{
    FILE *f = fopen(path, "r");
    char line[256];
    size_t kl = strlen(key);
    int found = 0;
    if (!f) return 0;
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        if (!strncmp(line, key, kl) && line[kl] == '=') {
            snprintf(out, cap, "%s", line + kl + 1);
            found = 1;
            break;
        }
    }
    fclose(f);
    return found;
}

/* printf_encode-aehnlich: WifiSsid.createFromAsciiEncoded erwartet ASCII mit \xHH. */
static void kw_encode_ssid(const char *in, char *out, size_t cap)
{
    size_t o = 0;
    for (; *in && o + 5 < cap; in++) {
        unsigned char c = (unsigned char)*in;
        if (c >= 0x20 && c < 0x7f && c != '\\' && c != '"') out[o++] = (char)c;
        else o += (size_t)snprintf(out + o, cap - o, "\\x%02x", c);
    }
    out[o] = 0;
}

/* Android NDK r10e kennt SOCK_CLOEXEC nicht. Setze FD_CLOEXEC portabel nach dem Erzeugen. */
static int kw_socket(int domain, int type)
{
    int s = socket(domain, type, 0);
    if (s >= 0 && fcntl(s, F_SETFD, FD_CLOEXEC) < 0) {
        close(s);
        return -1;
    }
    return s;
}

static int kw_host_link(const char *iface, struct kw_link *l)
{
    struct ifreq ifr;
    int s, i;
    FILE *f;
    char line[256];
    memset(l, 0, sizeof *l);
    snprintf(l->mac, sizeof l->mac, "02:4b:6f:00:00:02");
    s = kw_socket(AF_INET, SOCK_DGRAM);
    if (s < 0) return -1;
    memset(&ifr, 0, sizeof ifr);
    snprintf(ifr.ifr_name, sizeof ifr.ifr_name, "%s", iface);
    if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0) { close(s); return -1; }
    {
        int flags = ifr.ifr_flags;
        if (ioctl(s, SIOCGIFADDR, &ifr) == 0)
            l->ip = ((struct sockaddr_in *)&ifr.ifr_addr)->sin_addr.s_addr;
        snprintf(ifr.ifr_name, sizeof ifr.ifr_name, "%s", iface);
        if (ioctl(s, SIOCGIFNETMASK, &ifr) == 0)
            l->mask = ((struct sockaddr_in *)&ifr.ifr_netmask)->sin_addr.s_addr;
        snprintf(ifr.ifr_name, sizeof ifr.ifr_name, "%s", iface);
        if (ioctl(s, SIOCGIFHWADDR, &ifr) == 0) {
            const unsigned char *h = (const unsigned char *)ifr.ifr_hwaddr.sa_data;
            int nonzero = 0;
            for (i = 0; i < 6; i++) nonzero |= h[i];
            if (nonzero)
                snprintf(l->mac, sizeof l->mac, "%02x:%02x:%02x:%02x:%02x:%02x", h[0], h[1], h[2], h[3], h[4], h[5]);
        }
        l->up = (flags & IFF_UP) && l->ip != 0;
    }
    close(s);
    f = fopen("/proc/net/route", "r");
    if (f) {
        if (fgets(line, sizeof line, f)) { /* Kopfzeile */ }
        while (fgets(line, sizeof line, f)) {
            char name[32]; unsigned long dst, gw, flags;
            if (sscanf(line, "%31s %lx %lx %lx", name, &dst, &gw, &flags) == 4 &&
                !strcmp(name, iface) && dst == 0 && (flags & 2)) { l->gw = (uint32_t)gw; break; }
        }
        fclose(f);
    }
    if (!l->mask) l->mask = htonl(0xffffff00u);
    return 0;
}

/* ------------------------------------------------------------------ Ereignisse */

static void kw_schedule(struct kw *w, int kind, long delay_ms)
{
    int i;
    for (i = 0; i < w->nev; i++) if (w->ev[i].kind == kind) return;   /* nicht doppelt einreihen */
    if (w->nev >= KW_MAX_EV) return;
    w->ev[w->nev].due = now_ms() + delay_ms;
    w->ev[w->nev].kind = kind;
    w->nev++;
}

/*
 * KitKat-WifiMonitor ordnet Ereignisse OHNE "IFNAME=<iface> " dem p2p0-Monitor zu (nicht wlan0);
 * der echte Supplicant haengt das Praefix an. Deshalb: "<3>IFNAME=wlan0 CTRL-EVENT-...".
 */
static void kw_emit(struct kw *w, const char *text)
{
    int i;
    char buf[640];
    size_t len;
    if (!strncmp(text, "<3>", 3)) snprintf(buf, sizeof buf, "<3>IFNAME=%s %s", w->iface, text + 3);
    else snprintf(buf, sizeof buf, "IFNAME=%s %s", w->iface, text);
    len = strlen(buf);
    for (i = 0; i < KW_MAX_MON; i++) {
        if (!w->mon[i].used) continue;
        if (sendto(w->socks[w->mon[i].sock], buf, len, MSG_DONTWAIT, (struct sockaddr *)&w->mon[i].addr, w->mon[i].len) < 0) {
            kw_log("Ereignis senden an Monitor %d: %s", i, strerror(errno));
            if (errno == ECONNREFUSED || errno == ENOENT || errno == ENOTCONN) w->mon[i].used = 0;   /* Monitor ist weg */
        }
    }
}

static void kw_do_event(struct kw *w, int kind)
{
    char enc[300], msg[512];
    switch (kind) {
    case EV_SYNC:
        if (!w->visible) return;
        kw_encode_ssid(w->ssid, enc, sizeof enc);
        snprintf(msg, sizeof msg, "<3>CTRL-EVENT-STATE-CHANGE id=0 state=9 BSSID=%s SSID=%s", KW_FAKE_BSSID, enc);
        kw_emit(w, msg);
        snprintf(msg, sizeof msg, "<3>CTRL-EVENT-CONNECTED - Connection to %s completed [id=0 id_str=]", KW_FAKE_BSSID);
        kw_emit(w, msg);
        w->last_sync = now_ms();
        kw_log("Ereignis: verbunden (%s)", w->ssid);
        break;
    case EV_DISC:
        snprintf(msg, sizeof msg, "<3>CTRL-EVENT-DISCONNECTED bssid=%s reason=3", KW_FAKE_BSSID);
        kw_emit(w, msg);
        kw_emit(w, "<3>CTRL-EVENT-STATE-CHANGE id=-1 state=0 BSSID=00:00:00:00:00:00");
        kw_log("Ereignis: getrennt");
        break;
    case EV_SCAN:
        kw_emit(w, "<3>CTRL-EVENT-SCAN-RESULTS ");
        break;
    default:
        break;
    }
}

static void kw_run_events(struct kw *w)
{
    int i = 0;
    long long t = now_ms();
    while (i < w->nev) {
        if (w->ev[i].due <= t) {
            int kind = w->ev[i].kind;
            memmove(&w->ev[i], &w->ev[i + 1], (size_t)(w->nev - i - 1) * sizeof w->ev[0]);
            w->nev--;
            kw_do_event(w, kind);
        } else i++;
    }
}

/* Gleicht den Host-Zustand ab; meldet Verbindungswechsel an Android. */
static void kw_refresh(struct kw *w, int refresh_ssid)
{
    struct kw_link l;
    int was = w->visible;
    if (kw_host_link(w->iface, &l) < 0) memset(&l, 0, sizeof l);
    w->link = l;
    w->link_up = l.up;
    if (refresh_ssid) {
        char s[96];
        if (kw_env_get(w->envfile, "SSID", s, sizeof s) && *s) snprintf(w->ssid, sizeof w->ssid, "%s", s);
        else if (!*w->ssid) snprintf(w->ssid, sizeof w->ssid, "Kobo-WLAN");
    }
    w->visible = w->link_up && !w->user_off;
    if (w->visible && !was) kw_schedule(w, EV_SYNC, 0);
    if (!w->visible && was) kw_schedule(w, EV_DISC, 0);
}

static void kw_sync_soon(struct kw *w, long delay_ms)
{
    if (!w->visible) return;
    if (w->last_sync && now_ms() - w->last_sync < 3000) return;     /* kein Ereignissturm bei STATUS-Polling */
    kw_schedule(w, EV_SYNC, delay_ms);
}

/* ------------------------------------------------------------------ Kommandos */

static int has_word(const char *cmd, const char *word)
{
    size_t n = strlen(word);
    return !strncasecmp(cmd, word, n) && (cmd[n] == 0 || cmd[n] == ' ');
}

/* Erzeugt die Antwort auf ein wpa_ctrl-Kommando. */
static size_t kw_command(struct kw *w, int si, const struct sockaddr_un *from, socklen_t fromlen, const char *cmd,
                         char *out, size_t cap)
{
    char enc[300];
    int n = 0;

    /* KitKat sendet jeden Befehl als "IFNAME=wlan0 <Befehl>" (Multi-Interface-Supplicant). */
    if (!strncmp(cmd, "IFNAME=", 7)) {
        const char *sp = strchr(cmd, ' ');
        cmd = sp ? sp + 1 : "";
        while (*cmd == ' ') cmd++;
    }
    if (has_word(cmd, "PING")) {
        n = snprintf(out, cap, "PONG\n");
    } else if (has_word(cmd, "ATTACH")) {
        int i, slot = -1;
        for (i = 0; i < KW_MAX_MON; i++) {
            if (w->mon[i].used && w->mon[i].sock == si && w->mon[i].len == fromlen &&
                !memcmp(&w->mon[i].addr, from, fromlen)) { slot = i; break; }
            if (!w->mon[i].used && slot < 0) slot = i;
        }
        if (slot < 0) slot = 0;                       /* aeltesten Monitor ersetzen */
        w->mon[slot].addr = *from; w->mon[slot].len = fromlen; w->mon[slot].used = 1; w->mon[slot].sock = si;
        kw_log("Monitor angemeldet");
        /* WifiStateMachine ist erst kurz nach dem Anmelden bereit: Zustand nachliefern. */
        w->last_sync = 0;
        kw_sync_soon(w, 1500);
        n = snprintf(out, cap, "OK\n");
    } else if (has_word(cmd, "DETACH")) {
        int i;
        for (i = 0; i < KW_MAX_MON; i++)
            if (w->mon[i].used && w->mon[i].sock == si && w->mon[i].len == fromlen &&
                !memcmp(&w->mon[i].addr, from, fromlen)) w->mon[i].used = 0;
        n = snprintf(out, cap, "OK\n");
    } else if (has_word(cmd, "TERMINATE")) {
        w->quit = 1;
        n = snprintf(out, cap, "OK\n");
    } else if (has_word(cmd, "STATUS")) {
        kw_encode_ssid(w->ssid, enc, sizeof enc);
        if (w->visible) {
            char ip[20];
            kw_ip_str(w->link.ip, ip, sizeof ip);
            n = snprintf(out, cap,
                "bssid=%s\nfreq=%d\nssid=%s\nid=0\nmode=station\npairwise_cipher=CCMP\ngroup_cipher=CCMP\n"
                "key_mgmt=WPA2-PSK\nwpa_state=COMPLETED\nip_address=%s\naddress=%s\n",
                KW_FAKE_BSSID, KW_FREQ, enc, ip, w->link.mac);
            kw_sync_soon(w, 300);                    /* Android-Supplicant meldet Zustand beim STATUS erneut */
        } else {
            n = snprintf(out, cap, "wpa_state=%s\naddress=%s\n", w->user_off ? "INACTIVE" : "DISCONNECTED", w->link.mac);
        }
    } else if (has_word(cmd, "LIST_NETWORKS")) {
        kw_encode_ssid(w->ssid, enc, sizeof enc);
        n = snprintf(out, cap, "network id / ssid / bssid / flags\n0\t%s\tany\t%s\n", enc, w->visible ? "[CURRENT]" : "");
    } else if (has_word(cmd, "GET_NETWORK")) {
        int id = -1; char var[48] = "";
        if (sscanf(cmd + 11, "%d %47s", &id, var) == 2 && id == 0) {
            if (!strcasecmp(var, "ssid")) { kw_encode_ssid(w->ssid, enc, sizeof enc); n = snprintf(out, cap, "\"%s\"\n", enc); }
            else if (!strcasecmp(var, "key_mgmt")) n = snprintf(out, cap, "NONE\n");
            else n = snprintf(out, cap, "FAIL\n");
        } else n = snprintf(out, cap, "FAIL\n");
    } else if (has_word(cmd, "ADD_NETWORK")) {
        n = snprintf(out, cap, "%d\n", w->next_net++);
    } else if (has_word(cmd, "SCAN_RESULTS")) {
        kw_encode_ssid(w->ssid, enc, sizeof enc);
        n = snprintf(out, cap, "bssid / frequency / signal level / flags / ssid\n");
        if (w->link_up && n > 0 && (size_t)n < cap)
            n += snprintf(out + n, cap - (size_t)n, "%s\t%d\t%d\t[ESS]\t%s\n", KW_FAKE_BSSID, KW_FREQ, KW_RSSI, enc);
    } else if (has_word(cmd, "BSS")) {
        /* KitKat: "BSS RANGE=<sid>- MASK=..." liefert Eintraege ab id sid; leere Antwort beendet die Schleife. */
        const char *r = strstr(cmd, "RANGE=");
        int sid = r ? atoi(r + 6) : (cmd[3] == ' ' ? atoi(cmd + 4) : 0);
        kw_encode_ssid(w->ssid, enc, sizeof enc);
        if (w->link_up && sid <= 0)
            n = snprintf(out, cap, "id=0\nbssid=%s\nfreq=%d\nlevel=%d\ntsf=0\nflags=[ESS]\nssid=%s\n====\n",
                         KW_FAKE_BSSID, KW_FREQ, KW_RSSI, enc);
        else n = 0;
    } else if (has_word(cmd, "SCAN")) {
        kw_schedule(w, EV_SCAN, 200);
        n = snprintf(out, cap, "OK\n");
    } else if (has_word(cmd, "SIGNAL_POLL")) {
        if (w->visible) n = snprintf(out, cap, "RSSI=%d\nLINKSPEED=72\nNOISE=9999\nFREQUENCY=%d\n", KW_RSSI, KW_FREQ);
        else n = snprintf(out, cap, "FAIL\n");
    } else if (has_word(cmd, "DRIVER")) {
        const char *sub = cmd + 6;
        while (*sub == ' ') sub++;
        if (!strncasecmp(sub, "MACADDR", 7)) n = snprintf(out, cap, "Macaddr = %s\n", w->link.mac);
        else if (!strncasecmp(sub, "LINKSPEED", 9)) n = snprintf(out, cap, "LinkSpeed 72\n");
        else if (!strncasecmp(sub, "RSSI", 4)) n = snprintf(out, cap, "%s rssi %d\n", w->ssid, KW_RSSI);
        else n = snprintf(out, cap, "OK\n");
    } else if (has_word(cmd, "DISCONNECT")) {
        w->user_off = 1;
        kw_refresh(w, 0);
        n = snprintf(out, cap, "OK\n");
    } else if (has_word(cmd, "RECONNECT") || has_word(cmd, "REASSOCIATE") || has_word(cmd, "SELECT_NETWORK") ||
               has_word(cmd, "ENABLE_NETWORK")) {
        w->user_off = 0;
        kw_refresh(w, 0);
        w->last_sync = 0;
        kw_sync_soon(w, 400);
        n = snprintf(out, cap, "OK\n");
    } else if (has_word(cmd, "SET") || has_word(cmd, "SET_NETWORK") || has_word(cmd, "DISABLE_NETWORK") ||
               has_word(cmd, "REMOVE_NETWORK") || has_word(cmd, "SAVE_CONFIG") || has_word(cmd, "RECONFIGURE") ||
               has_word(cmd, "AP_SCAN") || has_word(cmd, "LOG_LEVEL") || has_word(cmd, "BLACKLIST") ||
               has_word(cmd, "STA_AUTOCONNECT") || has_word(cmd, "SCAN_INTERVAL") || has_word(cmd, "BSS_FLUSH") ||
               has_word(cmd, "AUTOSCAN") || has_word(cmd, "WPS_CANCEL")) {
        n = snprintf(out, cap, "OK\n");
    } else {
        n = snprintf(out, cap, "FAIL\n");           /* P2P, WPS, TDLS ... : gibt es nicht */
    }
    if (n < 0) n = 0;
    if ((size_t)n >= cap) n = (int)cap - 1;
    return (size_t)n;
}

/* ------------------------------------------------------------------ Supplicant-Schleife */

static const char *kw_dir(void)
{
    const char *d = getenv("KOBO_WPA_DIR");
    return d && *d ? d : "/data/misc/wifi/sockets";
}

/*
 * KitKat (libhardware_legacy wifi.c, wifi_connect_to_supplicant) sucht den Kontrollsocket des
 * PRIMAeren Interfaces NICHT in /data/misc/wifi/sockets (das gilt nur fuer Zweit-Schnittstellen und
 * ab Android 5), sondern
 *   - existiert IFACE_DIR = /data/system/wpa_supplicant:  IFACE_DIR/<iface>
 *   - sonst der Name <iface> ohne "/": wpa_ctrl_open macht daraus /dev/socket/<iface>.
 * Die Attrappe lauscht deshalb auf allen diesen Pfaden (und legt IFACE_DIR an, damit KitKat den
 * absoluten Pfad nimmt). Mit gesetztem KOBO_WPA_DIR (Tests) gibt es die Zusatzpfade nur ueber
 * KOBO_WPA_ALT_DIR / KOBO_WPA_INIT_DIR, damit Tests nie den Host anfassen.
 */
static const char *kw_alt_dir(void)
{
    const char *d = getenv("KOBO_WPA_ALT_DIR");
    if (d) return *d ? d : NULL;
    return getenv("KOBO_WPA_DIR") ? NULL : "/data/system/wpa_supplicant";
}

static const char *kw_init_dir(void)
{
    const char *d = getenv("KOBO_WPA_INIT_DIR");
    if (d) return *d ? d : NULL;
    return getenv("KOBO_WPA_DIR") ? NULL : "/dev/socket";
}

static const char *kw_client_dir(void)
{
    const char *d = getenv("KOBO_WPA_CLIENT_DIR");
    return d && *d ? d : "/data/misc/wifi/sockets";
}

static const char *kw_envfile(void)
{
    const char *d = getenv("KOBO_NET_ENV");
    return d && *d ? d : "/data/local/tmp/kobo-net.env";
}

static int kw_mkdirs(const char *path)
{
    char tmp[200], *p;
    snprintf(tmp, sizeof tmp, "%s", path);
    for (p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(tmp, 0770) < 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(tmp, 0770) < 0 && errno != EEXIST) return -1;
    return 0;
}

/* Bindet einen Kontrollsocket. Rueckgabe: Socket oder -1 (Grund im Log). */
static int kw_bind_ctrl(const char *dir, const char *name, char *path, size_t cap, int mkdir_dir)
{
    struct sockaddr_un a;
    int sock;
    if (mkdir_dir) {
        if (kw_mkdirs(dir) < 0) { kw_log("Verzeichnis %s: %s", dir, strerror(errno)); return -1; }
        if (chown(dir, KW_AID_WIFI, KW_AID_WIFI) < 0) { /* nur als root moeglich; Tests laufen ohne */ }
        chmod(dir, 0771);
    }
    snprintf(path, cap, "%s/%s", dir, name);
    if (strlen(path) >= sizeof a.sun_path) { kw_log("Socket-Pfad zu lang: %s", path); return -1; }
    unlink(path);
    sock = kw_socket(AF_UNIX, SOCK_DGRAM);
    if (sock < 0) return -1;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    memcpy(a.sun_path, path, strlen(path));
    if (bind(sock, (struct sockaddr *)&a, sizeof a) < 0) {
        kw_log("bind %s: %s", path, strerror(errno));
        close(sock);
        return -1;
    }
    if (chown(path, KW_AID_WIFI, KW_AID_WIFI) < 0) { /* siehe oben */ }
    chmod(path, 0660);
    return sock;
}

static int kw_supplicant(const char *iface)
{
    struct kw *w = calloc(1, sizeof *w);
    char path[220], wname[IFNAMSIZ + 8];
    const char *alt, *idir;
    int s;
    long long next_tick = 0;
    unsigned ticks = 0;

    if (!w) return 1;
    snprintf(w->iface, sizeof w->iface, "%s", iface);
    snprintf(w->dir, sizeof w->dir, "%s", kw_dir());
    snprintf(w->envfile, sizeof w->envfile, "%s", kw_envfile());
    w->next_net = 1;
    umask(0);
    signal(SIGPIPE, SIG_IGN);
    alt = kw_alt_dir();
    idir = kw_init_dir();
    /* 1. KitKat-Primaerpfad: IFACE_DIR/<iface> (Verzeichnis anlegen -> Android waehlt diesen Zweig) */
    if (alt && (s = kw_bind_ctrl(alt, iface, path, sizeof path, 1)) >= 0) {
        w->socks[w->nsock] = s; snprintf(w->paths[w->nsock++], sizeof w->paths[0], "%s", path);
    }
    /* 2. Pfad der Zweit-Schnittstellen / aelterer Bruecken-Staende */
    if ((s = kw_bind_ctrl(w->dir, iface, path, sizeof path, 1)) >= 0) {
        w->socks[w->nsock] = s; snprintf(w->paths[w->nsock++], sizeof w->paths[0], "%s", path);
    }
    /* 3. Namen ohne "/": /dev/socket/<iface> (falls IFACE_DIR fehlt) und wpa_<iface> (Android 5) */
    if (idir) {
        snprintf(wname, sizeof wname, "wpa_%s", iface);
        if (w->nsock < KW_MAX_SOCK && (s = kw_bind_ctrl(idir, iface, path, sizeof path, 0)) >= 0) {
            w->socks[w->nsock] = s; snprintf(w->paths[w->nsock++], sizeof w->paths[0], "%s", path);
        }
        if (w->nsock < KW_MAX_SOCK && (s = kw_bind_ctrl(idir, wname, path, sizeof path, 0)) >= 0) {
            w->socks[w->nsock] = s; snprintf(w->paths[w->nsock++], sizeof w->paths[0], "%s", path);
        }
    }
    if (!w->nsock) { kw_log("kein Kontrollsocket gebunden"); return 1; }
    for (s = 0; s < w->nsock; s++) kw_log("Supplicant-Attrappe laeuft: %s, Host-Schnittstelle %s", w->paths[s], iface);
    /* Ereignisse ohne angemeldeten Monitor gehen ins Leere; ATTACH liefert den Zustand nach. */
    kw_refresh(w, 1);

    while (!w->quit) {
        struct pollfd p[KW_MAX_SOCK];
        long long t = now_ms();
        int timeout = 1000, i, si;
        for (si = 0; si < w->nsock; si++) { p[si].fd = w->socks[si]; p[si].events = POLLIN; p[si].revents = 0; }
        for (i = 0; i < w->nev; i++) {
            long long d = w->ev[i].due - t;
            if (d < 0) d = 0;
            if (d < timeout) timeout = (int)d;
        }
        if (poll(p, (nfds_t)w->nsock, timeout) > 0) {
            for (si = 0; si < w->nsock; si++) {
                if (!(p[si].revents & POLLIN)) continue;
                for (;;) {
                    char cmd[512], rep[2048];
                    struct sockaddr_un from;
                    socklen_t fl = sizeof from;
                    ssize_t r;
                    size_t rl;
                    memset(&from, 0, sizeof from);
                    r = recvfrom(w->socks[si], cmd, sizeof cmd - 1, MSG_DONTWAIT, (struct sockaddr *)&from, &fl);
                    if (r < 0) break;
                    cmd[r] = 0;
                    while (r > 0 && (cmd[r - 1] == '\n' || cmd[r - 1] == '\r')) cmd[--r] = 0;
                    if (strncasecmp(cmd, "PING", 4) && strncasecmp(cmd, "SIGNAL_POLL", 11) && strncasecmp(cmd, "STATUS", 6))
                        kw_log("Kommando (%s): %s", w->paths[si], cmd);
                    rl = kw_command(w, si, &from, fl, cmd, rep, sizeof rep);
                    if (fl > (socklen_t)sizeof(sa_family_t))
                        if (sendto(w->socks[si], rep, rl, MSG_DONTWAIT, (struct sockaddr *)&from, fl) < 0)
                            kw_log("Antwort an Client fehlgeschlagen: %s", strerror(errno));
                }
            }
        }
        t = now_ms();
        if (t >= next_tick) {
            next_tick = t + 1000;
            kw_refresh(w, (++ticks % 5) == 0);
        }
        kw_run_events(w);
    }
    /* Antwort auf TERMINATE ist raus; Android erwartet danach das Ende-Ereignis. */
    kw_emit(w, "<3>CTRL-EVENT-TERMINATING - signal 15 received");
    for (s = 0; s < w->nsock; s++) { unlink(w->paths[s]); close(w->socks[s]); }
    kw_log("Supplicant-Attrappe beendet");
    free(w);
    return 0;
}

/*
 * --probe IFACE: Selbsttest ohne Android-Logs. Verhaelt sich wie wifi_connect_to_supplicant +
 * wpa_ctrl_open aus system_server (uid 1000, Gruppe wifi): waehlt den Pfad wie KitKat, bindet einen
 * Client-Socket in /data/misc/wifi/sockets, verbindet und sendet PING. Gibt je Kandidat den
 * genauen errno aus -- damit zeigt net.txt, ob es an Pfad oder Rechten liegt.
 */
static void kw_probe_one(const char *label, const char *dest)
{
    struct sockaddr_un l, d;
    char cpath[220], buf[64];
    struct pollfd p;
    int s;
    ssize_t r;
    s = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (s < 0) { printf("probe %s %s: socket: %s\n", label, dest, strerror(errno)); return; }
    memset(&l, 0, sizeof l);
    l.sun_family = AF_UNIX;
    snprintf(cpath, sizeof l.sun_path, "%s/kobo_probe_%d", kw_client_dir(), (int)getpid());
    memcpy(l.sun_path, cpath, strlen(cpath) + 1);
    unlink(cpath);
    if (bind(s, (struct sockaddr *)&l, sizeof l) < 0) {
        printf("probe %s %s: Client-bind %s: %s\n", label, dest, cpath, strerror(errno)); close(s); return;
    }
    memset(&d, 0, sizeof d);
    d.sun_family = AF_UNIX;
    if (strlen(dest) >= sizeof d.sun_path) { printf("probe %s %s: Pfad zu lang\n", label, dest); close(s); return; }
    memcpy(d.sun_path, dest, strlen(dest) + 1);
    if (connect(s, (struct sockaddr *)&d, sizeof d) < 0) {
        printf("probe %s %s: connect: %s\n", label, dest, strerror(errno));
    } else if (send(s, "PING", 4, 0) < 0) {
        printf("probe %s %s: send: %s\n", label, dest, strerror(errno));
    } else {
        p.fd = s; p.events = POLLIN; p.revents = 0;
        if (poll(&p, 1, 1500) > 0 && (r = recv(s, buf, sizeof buf - 1, 0)) > 0) {
            buf[r] = 0;
            while (r > 0 && (buf[r - 1] == '\n' || buf[r - 1] == '\r')) buf[--r] = 0;
            printf("probe %s %s: OK (Antwort %s)\n", label, dest, buf);
        } else printf("probe %s %s: keine Antwort\n", label, dest);
    }
    close(s);
    unlink(cpath);
}

static int kw_probe(const char *iface)
{
    pid_t pid = fork();
    int status = 0;
    if (pid < 0) return 1;
    if (pid == 0) {
        gid_t groups[1] = { KW_AID_WIFI };
        char path[220];
        const char *alt = kw_alt_dir(), *idir = kw_init_dir();
        if (geteuid() == 0) {
            if (setgroups(1, groups) < 0 || setgid(1000) < 0 || setuid(1000) < 0) {
                printf("probe: Rechte auf uid 1000/gid wifi senken fehlgeschlagen: %s\n", strerror(errno));
                _exit(1);
            }
        }
        printf("probe: uid=%d gid=%d\n", (int)getuid(), (int)getgid());
        if (alt) {
            snprintf(path, sizeof path, "%s/%s", alt, iface);
            printf("probe: IFACE_DIR %s %s -> KitKat nimmt %s\n", alt, access(alt, F_OK) == 0 ? "vorhanden" : "FEHLT",
                   access(alt, F_OK) == 0 ? path : "/dev/socket/<iface>");
            kw_probe_one("IFACE_DIR", path);
        }
        snprintf(path, sizeof path, "%s/%s", kw_dir(), iface);
        kw_probe_one("misc/wifi/sockets", path);
        if (idir) {
            snprintf(path, sizeof path, "%s/%s", idir, iface);
            kw_probe_one("dev/socket", path);
            snprintf(path, sizeof path, "%s/wpa_%s", idir, iface);
            kw_probe_one("dev/socket/wpa_", path);
        }
        fflush(stdout);
        _exit(0);
    }
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { }
    return 0;
}

/* ------------------------------------------------------------------ dhcpcd-Attrappe */

static int kw_setprop(const char *name, const char *value)
{
    const char *bin = getenv("KOBO_SETPROP");
    pid_t pid;
    int status = 0;
    if (!bin || !*bin) bin = "/system/bin/setprop";
    pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        char *const argv[] = { (char *)"setprop", (char *)name, (char *)value, NULL };
        execv(bin, argv);
        _exit(127);
    }
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static int kw_dhcp_props(const char *iface, const struct kw_link *l)
{
    char key[96], val[64], ip[20], mask[20], gw[20], d1[64] = "", d2[64] = "";
    const char *env = kw_envfile();
    int rc = 0;
    kw_ip_str(l->ip, ip, sizeof ip);
    kw_ip_str(l->mask, mask, sizeof mask);
    kw_ip_str(l->gw, gw, sizeof gw);
    kw_env_get(env, "DNS1", d1, sizeof d1);
    kw_env_get(env, "DNS2", d2, sizeof d2);
    if (!*d1 && l->gw) snprintf(d1, sizeof d1, "%s", gw);      /* Router als DNS-Proxy, wenn der Host nichts liefert */
#define SET(suffix, value) do { snprintf(key, sizeof key, "dhcp.%s." suffix, iface); \
        if (kw_setprop(key, (value)) < 0) { kw_log("setprop %s fehlgeschlagen", key); rc = -1; } } while (0)
    SET("ipaddress", ip);
    SET("mask", mask);
    SET("gateway", l->gw ? gw : "");
    SET("server", l->gw ? gw : ip);
    SET("dns1", d1);
    SET("dns2", d2);
    SET("dns3", "");
    SET("dns4", "");
    SET("domain", "");
    SET("vendorInfo", "");
    SET("leasetime", "4294967295");        /* unendlich: Android plant keine Erneuerung */
    snprintf(val, sizeof val, "%d", (int)getpid());
    SET("pid", val);
    SET("reason", "BOUND");
    SET("result", "ok");                    /* zuletzt: libnetutils wartet auf diese Property */
#undef SET
    kw_log("DHCP-Attrappe: %s ip=%s mask=%s gw=%s dns=%s,%s", iface, ip, mask, gw, d1, d2);
    return rc;
}

static int kw_dhcp(const char *iface)
{
    struct kw_link l;
    int i;
    for (i = 0; i < 25; i++) {
        if (kw_host_link(iface, &l) == 0 && l.up) break;
        sleep(1);
    }
    if (i >= 25) { kw_log("DHCP-Attrappe: %s hat keine IPv4-Adresse (Host-WLAN nicht verbunden)", iface); return 1; }
    if (kw_dhcp_props(iface, &l) < 0) return 1;
    if (getenv("KOBO_WPA_ONESHOT")) return 0;      /* Tests */
    /* Der init-Dienst muss "running" bleiben, bis Android ctl.stop sendet. */
    for (;;) pause();
}

static int kw_ipinfo(const char *iface)
{
    struct kw_link l;
    char ip[20], mask[20], gw[20], ssid[96] = "", d1[64] = "", d2[64] = "";
    if (kw_host_link(iface, &l) < 0) { printf("iface=%s fehlt\n", iface); return 1; }
    kw_ip_str(l.ip, ip, sizeof ip); kw_ip_str(l.mask, mask, sizeof mask); kw_ip_str(l.gw, gw, sizeof gw);
    kw_env_get(kw_envfile(), "SSID", ssid, sizeof ssid);
    kw_env_get(kw_envfile(), "DNS1", d1, sizeof d1);
    kw_env_get(kw_envfile(), "DNS2", d2, sizeof d2);
    printf("iface=%s up=%d ip=%s mask=%s gw=%s mac=%s ssid=%s dns1=%s dns2=%s\n",
           iface, l.up, ip, mask, gw, l.mac, ssid, d1, d2);
    return 0;
}

#ifndef KOBO_WIFI_TEST
int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "--supplicant";
    const char *iface = argc > 2 ? argv[2] : "wlan0";
    /* Aufruf wie vom echten wpa_supplicant ("-iwlan0 ...") wird toleriert. */
    if (argc > 1 && argv[1][0] == '-' && argv[1][1] == 'i') { mode = "--supplicant"; iface = argv[1] + 2; }
    if (strlen(iface) >= IFNAMSIZ) { fputs("Schnittstellenname zu lang\n", stderr); return 2; }
    if (!strcmp(mode, "--supplicant")) return kw_supplicant(iface);
    if (!strcmp(mode, "--dhcp")) return kw_dhcp(iface);
    if (!strcmp(mode, "--ipinfo")) return kw_ipinfo(iface);
    if (!strcmp(mode, "--probe")) return kw_probe(iface);
    fputs("Aufruf: kobo-wpa --supplicant|--dhcp|--ipinfo|--probe IFACE\n", stderr);
    return 2;
}
#endif
