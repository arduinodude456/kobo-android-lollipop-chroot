# SPDX-License-Identifier: MIT
"""Host integration tests; no Kobo hardware or privileged uinput is assumed."""
import contextlib
import mmap
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = r'''
#define _GNU_SOURCE
#define _LARGEFILE64_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef FBIO_WAITFORVSYNC
#define FBIO_WAITFORVSYNC _IOW('F', 0x20, uint32_t)
#endif
int main(int argc, char **argv) {
    int fd=open("/dev/graphics/fb0", O_RDWR), d, d2, dir, p[2], n;
    unsigned w=(unsigned)atoi(getenv("KOBO_FB_WIDTH")), h=(unsigned)atoi(getenv("KOBO_FB_HEIGHT"));
    struct fb_var_screeninfo v,bad; struct fb_fix_screeninfo f; struct stat st; uint32_t crtc=0;
    if(fd<0) { perror("open fakefb"); return 1; }
    assert(!ioctl(fd,FBIOGET_VSCREENINFO,&v));
    assert(v.xres==w && v.yres==h && v.xres_virtual==w && v.yres_virtual==h*2 && v.bits_per_pixel==16);
    if(argc==3 && !strcmp(argv[1],"flip")) {
        v.yoffset=(unsigned)atoi(argv[2]); assert(!ioctl(fd,FBIOPAN_DISPLAY,&v)); close(fd); return 0;
    }
    assert(!ioctl(fd,FBIOGET_FSCREENINFO,&f));
    assert(f.line_length==w*2 && f.smem_len==w*h*4 && f.ypanstep==1 && f.visual==FB_VISUAL_TRUECOLOR);
    assert(!fstat(fd,&st) && st.st_size==w*h*4);
    d=dup(fd); assert(d>=0); close(fd); assert(!ioctl(d,FBIOGET_VSCREENINFO,&v));
    d2=fcntl(d,F_DUPFD,100); assert(d2>=100); close(d); assert(!ioctl(d2,FBIOGET_VSCREENINFO,&v));
    assert(dup2(d2,d2)==d2); d=dup2(d2,90); assert(d==90); close(d2);
    assert(!ioctl(d,FBIOGET_VSCREENINFO,&v));
    dir=open("/dev",O_RDONLY|O_DIRECTORY); assert(dir>=0);
    fd=openat(dir,"fb0",O_RDWR); assert(fd>=0); close(dir);
    assert(!ioctl(fd,FBIOGET_FSCREENINFO,&f)); close(fd);
    fd=open64("/dev/fb0",O_RDWR); assert(fd>=0); close(fd);
    fd=openat64(AT_FDCWD,"/dev/fb0",O_RDWR); assert(fd>=0); close(fd);
    { unsigned char *pixels=mmap(NULL,f.smem_len,PROT_READ|PROT_WRITE,MAP_SHARED,d,0);
      assert(pixels!=MAP_FAILED); pixels[0]=0x1f; pixels[1]=0; munmap(pixels,f.smem_len); }
    bad=v; bad.xres++; assert(ioctl(d,FBIOPUT_VSCREENINFO,&bad)==-1 && errno==EINVAL);
    bad=v; bad.yres_virtual--; assert(ioctl(d,FBIOPUT_VSCREENINFO,&bad)==-1 && errno==EINVAL);
    bad=v; bad.red.offset=0; assert(ioctl(d,FBIOPUT_VSCREENINFO,&bad)==-1 && errno==EINVAL);
    bad=v; bad.bits_per_pixel=32; assert(ioctl(d,FBIOPUT_VSCREENINFO,&bad)==-1 && errno==EINVAL);
    bad=v; bad.yoffset=h+1; assert(ioctl(d,FBIOPAN_DISPLAY,&bad)==-1 && errno==EINVAL);
    bad=v; bad.xoffset=1; assert(ioctl(d,FBIOPAN_DISPLAY,&bad)==-1 && errno==EINVAL);
    assert(ioctl(d,FBIOGET_VSCREENINFO,NULL)==-1 && errno==EFAULT);
    assert(!ioctl(d,FBIO_WAITFORVSYNC,&crtc)); crtc=1;
    assert(ioctl(d,FBIO_WAITFORVSYNC,&crtc)==-1 && errno==EINVAL);
    assert(!ioctl(d,FBIOBLANK,0)); assert(!ioctl(d,FBIOBLANK,4));
    assert(ioctl(d,FBIOBLANK,5)==-1 && errno==EINVAL);
    bad=v; bad.yoffset=h; bad.activate=FB_ACTIVATE_TEST;
    assert(!ioctl(d,FBIOPUT_VSCREENINFO,&bad)); assert(!ioctl(d,FBIOGET_VSCREENINFO,&bad) && bad.yoffset==0);
    v.yoffset=h; assert(!ioctl(d,FBIOPAN_DISPLAY,&v));
    assert(!ioctl(d,FBIOGET_VSCREENINFO,&bad) && bad.yoffset==h);
    v.yoffset=0; assert(!ioctl(d,FBIOPUT_VSCREENINFO,&v));
    assert(!pipe(p)); assert(write(p[1],"abc",3)==3); assert(!ioctl(p[0],FIONREAD,&n) && n==3);
    close(p[0]); close(p[1]);
    fd=open("/dev/null",O_RDONLY); assert(fd>=0);
    assert(ioctl(fd,FBIOGET_VSCREENINFO,&v)==-1 && errno==ENOTTY); close(fd);
    assert(ioctl(-1,FBIOGET_VSCREENINFO,&v)==-1 && errno==EBADF);
    close(d); assert(close(d)==-1 && errno==EBADF); return 0;
}
'''


def recvn(sock, length):
    result = bytearray()
    while len(result) < length:
        part = sock.recv(length - len(result))
        if not part:
            raise EOFError("RFB peer closed")
        result.extend(part)
    return bytes(result)


class RFB:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=2)
        self.sock.settimeout(2)
        assert recvn(self.sock, 12) == b"RFB 003.008\n"
        self.sock.sendall(b"RFB 003.008\n")
        assert recvn(self.sock, 2) == b"\x01\x01"
        self.sock.sendall(b"\x01")
        assert recvn(self.sock, 4) == bytes(4)
        self.sock.sendall(b"\x01")
        init = recvn(self.sock, 24)
        self.width, self.height = struct.unpack(">HH", init[:4])
        self.name = recvn(self.sock, struct.unpack(">I", init[20:24])[0])
        self.bpp = 2

    def close(self):
        self.sock.close()

    def request(self, incremental=False, x=0, y=0, w=None, h=None):
        self.sock.sendall(struct.pack(">BBHHHH", 3, int(incremental), x, y,
                                      self.width if w is None else w,
                                      self.height if h is None else h))

    def update(self):
        header = recvn(self.sock, 4)
        assert header[:2] == b"\x00\x00"
        result = []
        for _ in range(struct.unpack(">H", header[2:])[0]):
            x, y, w, h, encoding = struct.unpack(">HHHHi", recvn(self.sock, 12))
            assert encoding == 0
            result.append((x, y, w, h, recvn(self.sock, w * h * self.bpp)))
        return result

    def pixel_format(self, bits, big=False, shifts=(16, 8, 0)):
        depth = 16 if bits == 16 else 24
        maxima = (31, 63, 31) if bits == 16 else (255, 255, 255)
        pf = struct.pack(">BBBBHHHBBB3x", bits, depth, int(big), 1, *maxima, *shifts)
        self.sock.sendall(b"\x00\x00\x00\x00" + pf)
        self.bpp = bits // 8


class NativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("cc") or not shutil.which("make"):
            raise unittest.SkipTest("requires a host C toolchain")
        cls.buildtemp = tempfile.TemporaryDirectory(prefix="kobo-native-build-")
        cls.build = Path(cls.buildtemp.name)
        subprocess.run(["make", "-C", str(ROOT / "native"), "-j2",
                        "BUILD_DIR=" + str(cls.build), "STATIC=1",
                        "CFLAGS=-O2 -std=gnu99 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2"], check=True, capture_output=True)
        source = cls.build / "fb-helper.c"
        source.write_text(HELPER)
        cls.helper = cls.build / "fb-helper"
        subprocess.run(["cc", "-std=gnu99", "-Wall", "-Wextra", "-Werror", str(source),
                        "-o", str(cls.helper)], check=True, capture_output=True)
        cls.vnc = cls.build / "kobo-vnc"

    @classmethod
    def tearDownClass(cls):
        cls.buildtemp.cleanup()

    def env(self, shared, w=8, h=6):
        return dict(os.environ, LD_PRELOAD=str(self.build / "libkobofb.so"),
                    KOBO_FB_DIR=str(shared), KOBO_FB_WIDTH=str(w), KOBO_FB_HEIGHT=str(h))

    def test_preload_ioctls_dup_mmap_and_metadata(self):
        with tempfile.TemporaryDirectory() as td:
            run = subprocess.run([str(self.helper)], env=self.env(td), capture_output=True)
            self.assertEqual(run.returncode, 0, run.stderr.decode())
            m = struct.unpack("<16I", (Path(td) / "fb.meta").read_bytes())
            self.assertEqual(m[:6], (0x4B464231, 1, 64, 8, 6, 16))
            self.assertEqual(m[6:9], (0, 2, 4))
            self.assertEqual((Path(td) / "fb.bin").stat().st_size, 8 * 6 * 4)
            self.assertEqual((Path(td) / "fb.bin").read_bytes()[:2], b"\x1f\x00")

    PERF_HELPER = r"""
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int __android_log_print(int prio, const char *tag, const char *fmt, ...);
int main(void) {
    int p[2], a, b, c;
    if (pipe(p)) return 2;
    errno = 0; a = fsync(p[0]); b = fdatasync(p[0]);
    errno = 0; c = fsync(-1);
    printf("%d %d %d %d\n", a, b, c, errno == EBADF);
    __android_log_print(4, "T", "info %d", 1);
    __android_log_print(3, "T", "debug %d", 2);
    __android_log_print(6, "T", "error %d", 3);
    return 0;
}
"""

    def run_perf(self, extra):
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "perf.c"
            src.write_text(self.PERF_HELPER)
            exe = Path(td) / "perf"
            subprocess.run(["cc", "-std=gnu99", "-w", str(src), "-L" + str(self.build), "-lkobofb", "-Wl,-rpath," + str(self.build), "-o", str(exe)], check=True, capture_output=True)
            log = Path(td) / "android.log"
            env = dict(os.environ, LD_PRELOAD=str(self.build / "libkobofb.so"), KOBO_LOG_FILE=str(log), **extra)
            run = subprocess.run([str(exe)], env=env, capture_output=True)
            self.assertEqual(run.returncode, 0, run.stderr.decode())
            return run.stdout.decode().split(), (log.read_text() if log.exists() else "")

    def test_fsync_is_noop_by_default_but_keeps_ebadf(self):
        out, _ = self.run_perf({})
        self.assertEqual(out, ["0", "0", "-1", "1"])      # fsync(pipe) sonst EINVAL; fsync(-1) bleibt EBADF
        out, _ = self.run_perf({"KOBO_NOSYNC": "0"})
        self.assertEqual(out[:3], ["-1", "-1", "-1"])      # echter Syscall: Pipe nicht synchronisierbar

    def test_log_level_filter_and_persistent_descriptor(self):
        _, log = self.run_perf({})
        self.assertIn("I/T(", log); self.assertIn("E/T(", log)
        self.assertNotIn("debug 2", log)
        _, log = self.run_perf({"KOBO_LOG_LEVEL": "3"})
        self.assertIn("debug 2", log)
        _, log = self.run_perf({"KOBO_LOG_LEVEL": "6"})
        self.assertNotIn("info 1", log); self.assertIn("error 3", log)

    def test_dimensions_reject_bad_environment(self):
        for width in ("0", "4097", "-1", "8junk", ""):
            with self.subTest(width=width), tempfile.TemporaryDirectory() as td:
                run = subprocess.run([str(self.helper)], env=self.env(td, width), capture_output=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertIn(b"Invalid argument", run.stderr)

    @contextlib.contextmanager
    def server(self):
        with tempfile.TemporaryDirectory() as td:
            shared = Path(td) / "shared"
            reserve = socket.socket()
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
            reserve.close()
            proc = subprocess.Popen([str(self.vnc), "--shared", str(shared), "--no-input",
                                     "--width", "8", "--height", "6", "--port", str(port)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 3
                while not (shared / "fb.bin").exists() or not (shared / "fb.meta").exists():
                    if proc.poll() is not None:
                        self.fail(proc.communicate()[1].decode())
                    if time.monotonic() > deadline:
                        self.fail("server did not initialize framebuffer")
                    time.sleep(0.01)
                client = None
                while client is None:
                    try:
                        client = RFB(port)
                    except ConnectionRefusedError:
                        if time.monotonic() > deadline:
                            raise
                        time.sleep(0.01)
                try:
                    yield shared, client, proc, port
                finally:
                    client.close()
            finally:
                proc.terminate()
                try:
                    proc.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.communicate()
                    self.fail("server failed to exit promptly")

    def paint(self, shared, page, row, color):
        with (shared / "fb.bin").open("r+b") as f, mmap.mmap(f.fileno(), 0) as pixels:
            start = (page * 6 + row) * 16
            pixels[start:start+16] = struct.pack("<H", color) * 8

    def test_rfb_initialization_rgb565_and_incremental_rows(self):
        with self.server() as (shared, c, proc, port):
            self.assertEqual((c.width, c.height), (8, 6))
            self.assertEqual((shared / "fb.meta").stat().st_size, 64)
            self.assertEqual((shared / "fb.bin").stat().st_size, 192)
            c.request()
            self.assertEqual(c.update(), [(0, 0, 8, 6, bytes(96))])
            c.request(True)
            c.sock.settimeout(0.15)
            with self.assertRaises(socket.timeout):
                c.sock.recv(1)
            # A pending incremental request must NOT block new input messages.
            c.sock.sendall(struct.pack(">BBHI", 4, 1, 0, ord("a")))
            c.sock.sendall(struct.pack(">BBHH", 5, 1, 3, 4))
            self.paint(shared, 0, 2, 0xF800)
            c.sock.settimeout(2)
            self.assertEqual(c.update(), [(0, 2, 8, 1, b"\x00\xf8" * 8)])
            self.assertIsNone(proc.poll())
            c.request(True)
            self.paint(shared, 0, 1, 0x07E0)
            self.paint(shared, 0, 4, 0x001F)
            update = c.update()
            self.assertEqual(update[0][:4], (0, 1, 8, 4))

    def test_incremental_update_is_narrowed_to_changed_columns(self):
        with self.server() as (shared, c, _, _):
            c.request(); c.update()
            c.request(True)
            with (shared / "fb.bin").open("r+b") as f, mmap.mmap(f.fileno(), 0) as pixels:
                start = 2 * 16 + 2 * 2          # row 2, pixels 2 and 3 of an 8x6 page
                pixels[start:start + 4] = struct.pack("<H", 0xF800) * 2
            self.assertEqual(c.update(), [(2, 2, 2, 1, b"\x00\xf8" * 2)])
            # A 32 bit client gets the same narrow rectangle, converted in one pass.
            c.pixel_format(32, False, (16, 8, 0))
            c.request(False, 0, 2, 8, 1)
            self.assertEqual(c.update()[0][:4], (0, 2, 8, 1))

    def test_pending_incremental_accepts_new_full_request(self):
        with self.server() as (_, c, _, _):
            c.request(); c.update()
            c.request(True)
            c.sock.sendall(struct.pack(">BBHI", 4, 0, 0, 0xFF1B))
            c.request(False, 1, 2, 3, 2)
            self.assertEqual(c.update(), [(1, 2, 3, 2, bytes(12))])

    def test_page_flip_via_preload(self):
        with self.server() as (shared, c, _, _):
            c.request(); c.update()
            self.paint(shared, 1, 3, 0x07E0)
            c.request(True)
            subprocess.run([str(self.helper), "flip", "6"], env=self.env(shared), check=True, capture_output=True)
            self.assertEqual(c.update(), [(0, 3, 8, 1, b"\xe0\x07" * 8)])
            metadata = struct.unpack("<16I", (shared / "fb.meta").read_bytes())
            self.assertEqual(metadata[6:8], (6, 1))

    def test_rgb888_formats_and_endianness(self):
        for bits, big in ((24, False), (24, True), (32, False), (32, True), (16, True)):
            with self.subTest(bits=bits, big=big), self.server() as (shared, c, _, _):
                self.paint(shared, 0, 0, 0xF800)
                shifts = (11, 5, 0) if bits == 16 else (16, 8, 0)
                c.pixel_format(bits, big, shifts)
                c.request(False, 0, 0, 8, 1)
                pixel = (0xF800 if bits == 16 else 0xFF0000).to_bytes(bits // 8, "big" if big else "little")
                self.assertEqual(c.update(), [(0, 0, 8, 1, pixel * 8)])

    def test_zero_rectangle_and_clipped_request_validation(self):
        with self.server() as (_, c, _, _):
            c.request(False, 8, 6, 0, 0)
            self.assertEqual(c.update(), [])
            c.request(False, 7, 0, 2, 1)
            with self.assertRaises((EOFError, ConnectionResetError)):
                recvn(c.sock, 1)

    def test_malformed_messages_disconnect_and_reconnect(self):
        messages = [
            b"\xff",  # unknown message
            b"\x00\x00\x00\x00" + bytes(16),  # palette/zero bpp
            b"\x02\x00\x00\x81",  # too many encodings
            b"\x06\x00\x00\x00" + struct.pack(">I", 65537),
            b"\x00\x00\x00\x00" + struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 31, 8, 0),
        ]
        for message in messages:
            with self.subTest(message=message), self.server() as (_, c, proc, port):
                c.sock.sendall(message)
                with self.assertRaises((EOFError, ConnectionResetError)):
                    recvn(c.sock, 1)
                c.close()
                next_client = RFB(port)
                next_client.request()
                self.assertEqual(len(next_client.update()), 1)
                next_client.close()
                self.assertIsNone(proc.poll())

    def test_partial_message_timeout_does_not_kill_server(self):
        with self.server() as (_, c, proc, port):
            c.sock.sendall(b"\x00")
            c.sock.settimeout(6)
            with self.assertRaises((EOFError, ConnectionResetError)):
                recvn(c.sock, 1)
            self.assertIsNone(proc.poll())
            other = RFB(port)
            other.request(); self.assertEqual(len(other.update()), 1)
            other.close()

    def test_probe_real_failures_and_no_input_not_implicit(self):
        env = dict(os.environ, KOBO_BINDER_DEVICE="/definitely/missing/binder",
                   KOBO_ASHMEM_DEVICE="/definitely/missing/ashmem")
        run = subprocess.run([str(self.vnc), "--check"], env=env, capture_output=True, timeout=10)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn(b"binder: cannot open", run.stderr)
        self.assertIn(b"ashmem: cannot open", run.stderr)
        self.assertIn(b"uinput:", run.stderr)
        self.assertIn(b"namespaces:", run.stderr)
        with tempfile.TemporaryDirectory() as td:
            run = subprocess.run([str(self.vnc), "--shared", td], capture_output=True)
            self.assertEqual(run.returncode, 2)
        run = subprocess.run([str(self.vnc), "--check", "--no-input"], capture_output=True)
        self.assertEqual(run.returncode, 2)

    def test_static_host_binary_and_cli_bounds(self):
        output = subprocess.run(["file", str(self.vnc)], check=True, capture_output=True).stdout
        self.assertIn(b"statically linked", output)
        for arguments in (("--width", "0"), ("--height", "4097"), ("--port", "65536"), ("--listen", "0.0.0.0")):
            run = subprocess.run([str(self.vnc), *arguments], capture_output=True)
            self.assertEqual(run.returncode, 2)


if __name__ == "__main__":
    unittest.main()
