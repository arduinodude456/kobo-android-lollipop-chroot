# SPDX-License-Identifier: MIT
"""Off-device checks only: no mount, Android boot or device flash is performed."""
import gzip
import hashlib
import importlib.util
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.tmp.name)
        shutil.copy(ROOT / 'runtime/install.sh', self.base / 'install.sh')
        self.payload = b'rootfs-fixture-not-an-android-image\n' * 128
        data = gzip.compress(self.payload, mtime=0)
        (self.base / 'rootfs.img.gz').write_bytes(data)
        (self.base / 'rootfs.size').write_text(str(len(self.payload)) + '\n')
        (self.base / 'rootfs.img.gz.sha256').write_text(hashlib.sha256(data).hexdigest() + '  rootfs.img.gz\n')

    def tearDown(self):
        self.tmp.cleanup()

    def install(self):
        return subprocess.run(['sh', str(self.base / 'install.sh')], cwd=self.base, capture_output=True, text=True)

    def test_verified_atomic_decompression(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'rootfs.img').read_bytes(), self.payload)
        self.assertFalse(list(self.base.glob('rootfs.img.new.*')))

    def test_existing_image_never_overwritten(self):
        (self.base / 'rootfs.img').write_bytes(b'existing-data')
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual((self.base / 'rootfs.img').read_bytes(), b'existing-data')

    def test_corruption_fails_without_image(self):
        (self.base / 'rootfs.img.gz').write_bytes(b'corruption')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse((self.base / 'rootfs.img').exists())

    def test_bad_size_fails_atomically(self):
        (self.base / 'rootfs.size').write_text('123\n')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse((self.base / 'rootfs.img').exists())
        self.assertFalse(list(self.base.glob('rootfs.img.new.*')))

    def test_shell_in_metadata_rejected(self):
        (self.base / 'rootfs.size').write_text('$(touch injected)\n')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse((self.base / 'injected').exists())


class RuntimeTests(unittest.TestCase):
    def test_runtime_syntax(self):
        for path in (ROOT / 'runtime').glob('*.sh'):
            subprocess.run(['sh', '-n', str(path)], check=True)

    def test_kernel_preflight_requires_devpts(self):
        source = (ROOT / 'runtime/android.sh').read_text()
        self.assertIn('grep -qw devpts /proc/filesystems', source)

    def test_container_compiles_strictly(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(['gcc', '-std=c99', '-O2', '-Wall', '-Wextra', '-Werror',
                            str(ROOT / 'runtime/kobo-container.c'), '-o', str(pathlib.Path(tmp) / 'container')], check=True)

    def test_private_namespace_required(self):
        source = (ROOT / 'runtime/kobo-container.c').read_text()
        self.assertIn('CLONE_NEWNS | CLONE_NEWPID', source)
        self.assertIn('getpid() != 1', source)
        self.assertIn('MS_REC | MS_PRIVATE', source)
        self.assertIn('rootfs lacks kobo-chroot marker', source)

    def test_built_rootfs_marker_matches_both_launchers(self):
        spec = importlib.util.spec_from_file_location('runtime_rootfs_test', ROOT / 'scripts/rootfs.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            product = base / 'product'
            (product / 'root').mkdir(parents=True)
            (product / 'system').mkdir()
            (product / 'root/init').write_bytes(b'fixture-only-not-Android')
            (product / 'system/build.prop').write_text('fixture=true\n')
            stage = base / 'stage'
            with mock.patch.object(builder, 'validate'):
                builder.prepare(product, stage)
            self.assertEqual((stage / 'kobo-chroot').read_text(), 'android-kitkat_api19\n')
            runtime = (ROOT / 'runtime/android.sh').read_text()
            self.assertIn('"$ROOTFS/kobo-chroot"', runtime)
            self.assertIn("= 'android-kitkat_api19'", runtime)
            self.assertIn('KitKat/API-19-Image erforderlich', runtime)
            self.assertIn('access("/kobo-chroot", F_OK)', (ROOT / 'runtime/kobo-container.c').read_text())
            with self.assertRaises(ValueError):
                builder.image(stage, base / 'too-large.img', 4096)
            self.assertFalse((base / 'too-large.img').exists())

    @unittest.skipUnless(shutil.which('luajit'), 'LuaJIT unavailable')
    def test_lua_parser(self):
        result = subprocess.run(['luajit', 'tests/test_lua.lua'], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
