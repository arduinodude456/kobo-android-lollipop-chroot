# SPDX-License-Identifier: MIT
"""Binder 32 -> 64 bit shim: ABI layout against the real uapi header and a functional
run against a simulated 64-bit binder kernel. Needs an ARM32 cross compiler and qemu-user
(Debian/Ubuntu: gcc-arm-linux-gnueabihf libc6-dev-armhf-cross qemu-user); skipped otherwise."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CC = shutil.which("arm-linux-gnueabihf-gcc")
QEMU = shutil.which("qemu-arm")
WARN = ["-std=gnu99", "-Wall", "-Wextra", "-Werror"]
HEADER = "/usr/arm-linux-gnueabihf/include/linux/android/binder.h"


@unittest.skipUnless(CC and QEMU, "requires arm-linux-gnueabihf-gcc and qemu-arm")
class BinderShimTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="kobo-binder-")
        cls.out = Path(cls.tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def compile(self, args, name):
        target = self.out / name
        run = subprocess.run([CC, *WARN, *args, "-o", str(target)], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        return target

    @unittest.skipUnless(Path(HEADER).exists(), "uapi binder.h not installed")
    def test_abi_matches_uapi_header(self):
        # Static assertions: any mismatch is a compile error.
        for side in ("k", "u"):
            with self.subTest(side=side):
                self.compile(["-c", str(ROOT / "tests" / f"binder_abi_check_{side}.c")], f"abi_{side}.o")

    @unittest.skipUnless(Path(HEADER).exists(), "uapi binder.h not installed")
    def test_translation_against_fake_64bit_kernel(self):
        exe = self.compile(["-O1", "-g", "-static", "-Wl,--wrap=malloc,--wrap=free,--wrap=realloc",
                            str(ROOT / "tests/binder_shim_test.c"), str(ROOT / "native/kobo_binder.c")], "shim_test")
        run = subprocess.run([QEMU, str(exe)], capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("binder shim tests passed", run.stdout)

    def test_preload_hook_is_wired_and_object_builds_for_arm(self):
        # kobofb.c itself is bionic-specific (glibc ARM aliases open64), so only the shim
        # object is cross-built here; the hook is checked in the source.
        obj = self.compile(["-march=armv7-a", "-mfpu=vfpv3-d16", "-Os", "-fPIC", "-c",
                            str(ROOT / "native/kobo_binder.c")], "kobo_binder.o")
        symbols = subprocess.run(["arm-linux-gnueabihf-nm", str(obj)], capture_output=True, text=True).stdout
        self.assertRegex(symbols, r" T kobo_binder_ioctl\n")
        src = (ROOT / "native/kobofb.c").read_text()
        self.assertIn("kobo_binder_wants((uint32_t)request)", src)
        self.assertLess(src.index("kobo_binder_wants"), src.index("fake_fd(fd)) return"))


if __name__ == "__main__":
    unittest.main()
