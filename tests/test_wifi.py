# SPDX-License-Identifier: MIT
"""Host-Tests der WLAN-Bruecke: wpa_ctrl-Protokoll der Supplicant-Attrappe, dhcpcd-Attrappe, Netz-Schutz."""
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CC = shutil.which("gcc")


def lo_usable():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0)); s.close(); return True
    except OSError:
        return False


@unittest.skipUnless(CC and lo_usable(), "gcc oder Loopback fehlt")
class WifiBridge(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.exe = Path(cls.tmp.name) / "kobo-wpa"
        r = subprocess.run([CC, "-std=gnu99", "-Wall", "-Wextra", "-Werror", str(ROOT / "native/kobo_wifi.c"), "-o", str(cls.exe)],
                           capture_output=True, text=True)
        assert r.returncode == 0, r.stderr

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def env(self, d):
        e = dict(os.environ)
        e.update(KOBO_WPA_DIR=str(d / "sock"), KOBO_NET_ENV=str(d / "net.env"), KOBO_WPA_LOG=str(d / "wpa.log"))
        (d / "net.env").write_text("SSID=Test Net\nDNS1=9.9.9.9\nDNS2=1.1.1.1\n")
        return e

    def client(self, d, name):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.bind(str(d / name)); s.connect(str(d / "sock" / "lo")); s.settimeout(5)
        return s

    def ask(self, s, cmd):
        s.send(cmd.encode()); return s.recv(4096).decode()

    def test_supplicant_protocol(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            p = subprocess.Popen([str(self.exe), "--supplicant", "lo"], env=self.env(d))
            try:
                for _ in range(50):
                    if (d / "sock" / "lo").exists(): break
                    time.sleep(0.1)
                ctrl, mon = self.client(d, "c1"), self.client(d, "c2")
                self.assertEqual(self.ask(ctrl, "PING"), "PONG\n")
                st = self.ask(ctrl, "STATUS")
                self.assertIn("wpa_state=COMPLETED", st); self.assertIn("ssid=Test Net", st); self.assertIn("ip_address=127.0.0.1", st)
                self.assertIn("\tTest Net\t", self.ask(ctrl, "LIST_NETWORKS"))
                self.assertEqual(self.ask(ctrl, 'GET_NETWORK 0 ssid'), '"Test Net"\n')
                self.assertEqual(self.ask(ctrl, "ADD_NETWORK"), "1\n")
                self.assertTrue(self.ask(ctrl, "DRIVER MACADDR").startswith("Macaddr = "))
                self.assertIn("Test Net", self.ask(ctrl, "SCAN_RESULTS"))
                self.assertEqual(self.ask(ctrl, "SET_NETWORK 0 ssid x"), "OK\n")
                self.assertEqual(self.ask(ctrl, "P2P_FIND"), "FAIL\n")
                # KitKat sendet alle Befehle mit "IFNAME=<iface> " davor
                self.assertEqual(self.ask(ctrl, "IFNAME=lo PING"), "PONG\n")
                self.assertTrue(self.ask(ctrl, "IFNAME=lo DRIVER MACADDR").startswith("Macaddr = "))
                self.assertEqual(self.ask(ctrl, "IFNAME=lo SET device_name x"), "OK\n")
                self.assertEqual(self.ask(ctrl, "IFNAME=lo RECONNECT"), "OK\n")
                self.assertIn("wpa_state=COMPLETED", self.ask(ctrl, "IFNAME=lo STATUS"))
                self.assertEqual(self.ask(ctrl, 'IFNAME=lo GET_NETWORK 0 ssid'), '"Test Net"\n')
                bss = self.ask(ctrl, "IFNAME=lo BSS RANGE=0- MASK=0x21987")
                self.assertIn("\nssid=Test Net\n====\n", bss); self.assertIn("level=-45", bss)
                ctrl.send(b"IFNAME=lo BSS RANGE=1- MASK=0x21987")
                self.assertEqual(ctrl.recv(4096), b"")       # leere Antwort muss trotzdem kommen
                # Monitor: nach ATTACH muss der Verbindungszustand nachgeliefert werden.
                self.assertEqual(self.ask(mon, "ATTACH"), "OK\n")
                seen = ""
                while "CTRL-EVENT-CONNECTED" not in seen:
                    seen += mon.recv(4096).decode()
                self.assertIn("state=9", seen)
                # ohne IFNAME-Praefix wuerde KitKat die Ereignisse dem p2p0-Monitor geben
                self.assertIn("<3>IFNAME=lo CTRL-EVENT-STATE-CHANGE", seen); self.assertIn("<3>IFNAME=lo CTRL-EVENT-CONNECTED", seen)
                # Format, das WifiMonitor.mConnectedEventPattern verlangt
                m = re.search(r"((?:[0-9a-f]{2}:){5}[0-9a-f]{2}) .* \[id=([0-9]+) ", seen.split("CONNECTED")[1].replace(" - Connection to", ""))
                self.assertTrue(m, seen)
                self.assertEqual(self.ask(ctrl, "DISCONNECT"), "OK\n")
                gone = ""
                while "DISCONNECTED" not in gone:
                    gone += mon.recv(4096).decode()
                self.assertIn("wpa_state=INACTIVE", self.ask(ctrl, "STATUS"))
                self.assertEqual(self.ask(ctrl, "RECONNECT"), "OK\n")
                back = ""
                while "CTRL-EVENT-CONNECTED" not in back:
                    back += mon.recv(4096).decode()
                self.assertEqual(self.ask(ctrl, "TERMINATE"), "OK\n")
                self.assertEqual(p.wait(timeout=5), 0)
                self.assertFalse((d / "sock" / "lo").exists())
            finally:
                if p.poll() is None: p.kill()

    def test_kitkat_socket_paths(self):
        """KitKat sucht IFACE_DIR/<iface> bzw. /dev/socket/<iface>; dort muss die Attrappe antworten,
        und Ereignisse muessen ueber denselben Socket zurueckkommen (connected-Datagramm-Socket)."""
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            e = self.env(d)
            e.update(KOBO_WPA_ALT_DIR=str(d / "iface_dir"), KOBO_WPA_INIT_DIR=str(d / "devsock"))
            (d / "devsock").mkdir()
            p = subprocess.Popen([str(self.exe), "--supplicant", "lo"], env=e)
            try:
                paths = [d / "iface_dir" / "lo", d / "sock" / "lo", d / "devsock" / "lo", d / "devsock" / "wpa_lo"]
                for _ in range(50):
                    if all(x.exists() for x in paths): break
                    time.sleep(0.1)
                for i, path in enumerate(paths):
                    self.assertTrue(path.exists(), path)
                    ctrl, mon = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM), socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
                    for k, c in enumerate((ctrl, mon)):
                        c.bind(str(d / ("k%d_%d" % (i, k)))); c.connect(str(path)); c.settimeout(5)
                    self.assertEqual(self.ask(ctrl, "PING"), "PONG\n", path)
                    self.assertEqual(self.ask(mon, "ATTACH"), "OK\n")
                    seen = ""
                    while "CTRL-EVENT-CONNECTED" not in seen:
                        seen += mon.recv(4096).decode()
                    ctrl.close(); mon.close()
                self.assertTrue(os.stat(d / "iface_dir").st_mode & 0o111)
                self.assertEqual(self.ask(self.client(d, "last"), "TERMINATE"), "OK\n")
                self.assertEqual(p.wait(timeout=5), 0)
                for path in paths: self.assertFalse(path.exists(), path)
            finally:
                if p.poll() is None: p.kill()

    @unittest.skipUnless(os.geteuid() == 0, "--probe senkt Rechte auf uid 1000, braucht root")
    def test_probe_selftest(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            os.chmod(d, 0o755)
            e = self.env(d)
            e.update(KOBO_WPA_ALT_DIR=str(d / "iface_dir"), KOBO_WPA_INIT_DIR="", KOBO_WPA_CLIENT_DIR=str(d / "cli"))
            (d / "cli").mkdir(); os.chmod(d / "cli", 0o777)
            p = subprocess.Popen([str(self.exe), "--supplicant", "lo"], env=e)
            try:
                for _ in range(50):
                    if (d / "iface_dir" / "lo").exists(): break
                    time.sleep(0.1)
                os.chmod(d / "sock", 0o755)
                r = subprocess.run([str(self.exe), "--probe", "lo"], env=e, capture_output=True, text=True, timeout=20)
                self.assertIn("uid=1000", r.stdout)
                self.assertIn("IFACE_DIR %s vorhanden" % (d / "iface_dir"), r.stdout)
                self.assertIn("iface_dir/lo: OK (Antwort PONG)", r.stdout)
                self.assertIn("misc/wifi/sockets", r.stdout)
            finally:
                p.kill(); p.wait()

    def test_dhcp_properties(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            sp = d / "setprop"
            sp.write_text('#!/bin/sh\necho "$1=$2" >> "%s"\n' % (d / "props"))
            sp.chmod(0o755)
            e = self.env(d); e.update(KOBO_SETPROP=str(sp), KOBO_WPA_ONESHOT="1")
            r = subprocess.run([str(self.exe), "--dhcp", "lo"], env=e, timeout=30)
            self.assertEqual(r.returncode, 0)
            lines = (d / "props").read_text().splitlines()
            props = dict(l.split("=", 1) for l in lines)
            self.assertEqual(props["dhcp.lo.ipaddress"], "127.0.0.1")
            self.assertEqual(props["dhcp.lo.dns1"], "9.9.9.9"); self.assertEqual(props["dhcp.lo.dns2"], "1.1.1.1")
            self.assertEqual(props["dhcp.lo.leasetime"], "4294967295")
            self.assertEqual(lines[-1], "dhcp.lo.result=ok", "result muss zuletzt gesetzt werden")

    def test_bad_interface_name_rejected(self):
        r = subprocess.run([str(self.exe), "--ipinfo", "x" * 40], capture_output=True)
        self.assertEqual(r.returncode, 2)


NET_C = r'''
#include "kobo_net.h"
#include <fcntl.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>
#define CK(c) do { if (!(c)) { printf("FAIL %d\n", __LINE__); return 1; } } while (0)
int main(void) {
    struct ifreq r; memset(&r, 0, sizeof r);
    strcpy(r.ifr_name, "wlan0");
    CK(kobo_net_blocks(SIOCSIFADDR, &r));
    CK(kobo_net_blocks(SIOCADDRT, &r) && kobo_net_blocks(SIOCDELRT, &r));
    r.ifr_flags = IFF_UP | IFF_RUNNING; CK(!kobo_net_blocks(SIOCSIFFLAGS, &r));
    r.ifr_flags = 0; CK(kobo_net_blocks(SIOCSIFFLAGS, &r));
    CK(!kobo_net_blocks(SIOCGIFADDR, &r) && !kobo_net_blocks(SIOCGIFFLAGS, &r));
    strcpy(r.ifr_name, "lo"); CK(!kobo_net_blocks(SIOCSIFADDR, &r));
    CK(kobo_net_hides_path("/proc/sys/net/ipv6/conf/wlan0/disable_ipv6", O_WRONLY));
    CK(!kobo_net_hides_path("/proc/sys/net/ipv6/conf/wlan0/disable_ipv6", O_RDONLY));
    CK(!kobo_net_hides_path("/proc/meminfo", O_WRONLY));
    puts("ok"); return 0;
}'''


@unittest.skipUnless(CC, "gcc fehlt")
class NetGuard(unittest.TestCase):
    def test_guard(self):
        with tempfile.TemporaryDirectory() as t:
            src = Path(t) / "t.c"; src.write_text(NET_C); exe = Path(t) / "t"
            r = subprocess.run([CC, "-std=gnu99", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "native"), str(src),
                                str(ROOT / "native/kobo_net.c"), "-o", str(exe)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(subprocess.run([str(exe)], capture_output=True, text=True).stdout.strip(), "ok")


class RuntimeIntegration(unittest.TestCase):
    def test_android_sh_wires_bridge(self):
        s = (ROOT / "runtime/android.sh").read_text()
        for needle in ("patch_net_rc", "KOBO_NET_BEGIN", "svc wifi enable", "install_non_market_apps", "netinfo",
                       "data/system/wpa_supplicant", "kobo-wpa --probe"):
            self.assertIn(needle, s)
        subprocess.run(["sh", "-n", str(ROOT / "runtime/android.sh")], check=True)

    def test_init_block_idempotent(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t); (d / "run").mkdir(); (d / "init.rc").write_text("on early-init\n    mkdir /x\n")
            script = (ROOT / "runtime/android.sh").read_text()
            start = script.index("patch_net_rc() {"); end = script.index("net_install() {")
            fn = script[start:end]
            sh = d / "t.sh"
            sh.write_text('ROOTFS="%s"; RUN="%s/run"\n%s\npatch_net_rc wlan0\npatch_net_rc wlan1\n' % (d, d, fn))
            subprocess.run(["sh", str(sh)], check=True)
            rc = (d / "init.rc").read_text()
            self.assertEqual(rc.count("KOBO_NET_BEGIN"), 1)
            self.assertIn("service dhcpcd_wlan1 /system/bin/kobo-wpa --dhcp wlan1", rc)
            self.assertNotIn("dhcpcd_wlan0", rc)
            self.assertTrue(rc.startswith("on early-init"))


if __name__ == "__main__":
    unittest.main()
