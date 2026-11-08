# SPDX-License-Identifier: MIT
"""Host-Test der Parcel-Helfer von kobo-healthd (Layout wie Android Parcel::writeString16)."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]
CC = shutil.which("gcc")
C = r'''
#define KOBO_HEALTHD_TEST
#include "../native/kobo_healthd.c"
#include <stdio.h>
#define CK(c) do { if (!(c)) { printf("FAIL %d\n", __LINE__); return 1; } } while (0)
int main(void) {
    uint8_t m[512]; struct kh_buf b = { m, sizeof m, 0, 0 }; uint32_t off, v;
    kh_build_add_service(&b, "batteryproperties", 0x4b48, &off);
    CK(!b.overflow); CK(b.len % 4 == 0);
    memcpy(&v, m, 4); CK(v == 0x100);
    CK(kh_parse_token(m, b.len, "android.os.IServiceManager") != 0);
    CK(kh_parse_token(m, b.len, "android.os.IBatteryPropertiesRegistrar") == 0);
    CK(off % 4 == 0); memcpy(&v, m + off, 4); CK(v == KB_TYPE_BINDER);
    CK(b.len == off + 16 + 4);
    b.len = 0; kh_build_props(&b);
    CK(kh_parse_token(m, b.len, "android.os.IBatteryPropertiesListener") != 0);
    size_t at = kh_parse_token(m, b.len, "android.os.IBatteryPropertiesListener");
    memcpy(&v, m + at, 4); CK(v == 1);
    memcpy(&v, m + at + 4, 4); CK(v == 1);         /* AC online */
    memcpy(&v, m + at + 4 + 6 * 4, 4); CK(v == 100); /* Level */
    memcpy(&v, m + at + 32, 4); CK(v == 4200);       /* Spannung */
    memcpy(&v, m + at + 36, 4); CK(v == 0);          /* batteryCurrentNow (KitKat 4.4.x) */
    memcpy(&v, m + at + 40, 4); CK(v == 0);          /* batteryChargeCounter */
    memcpy(&v, m + at + 44, 4); CK(v == 250);        /* Temperatur: sonst Over-Temp-Shutdown */
    memcpy(&v, m + at + 48, 4); CK(v == 6);          /* Laenge "Li-ion" */
    puts("ok"); return 0;
}'''
@unittest.skipUnless(CC, "gcc fehlt")
class HealthdParcel(unittest.TestCase):
    def test_parcels(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as t:
            src = Path(t) / "t.c"; src.write_text(C)
            exe = Path(t) / "t"
            r = subprocess.run([CC, "-std=gnu99", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-I", str(ROOT / "native"), str(src), "-o", str(exe)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(r.stdout.strip(), "ok", r.stdout)
if __name__ == "__main__":
    unittest.main()
