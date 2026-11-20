"""Exercise the VM image's actual camera module gate against rootfs fixtures."""
import pathlib
import re
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class VMCameraSupportTests(unittest.TestCase):
    def test_rootfs_gate(self):
        body = (ROOT / 'classes/camera-loopback-check.bbclass').read_text()
        body = body.split('python wendyos_check_camera_loopback_rootfs() {\n', 1)[1].rsplit('\n}', 1)[0]
        import textwrap
        code = compile(textwrap.dedent(body), 'camera-loopback-check', 'exec')
        class BB:
            @staticmethod
            def fatal(msg):
                raise RuntimeError(msg)
            @staticmethod
            def note(msg):
                pass
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            release = '7.2.8-test-vm'
            modules = root / 'usr/lib/modules' / release
            modules.mkdir(parents=True)
            config = root / 'config'
            config.write_text('CONFIG_VIDEO_DEV=m\nCONFIG_VIDEOBUF2_VMALLOC=m\n')
            release_file = root / 'release'
            release_file.write_text(release)
            files = {'extra/v4l2loopback.ko': ['kernel/videodev.ko', 'kernel/videobuf2-vmalloc.ko'],
                     'kernel/videodev.ko': [], 'kernel/videobuf2-vmalloc.ko': ['kernel/videobuf2-memops.ko'],
                     'kernel/videobuf2-memops.ko': []}
            for name in files:
                p = modules / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(b'fixture module')
            (modules / 'modules.dep').write_text(''.join(f'{name}: {" ".join(deps)}\n' for name, deps in files.items()))
            values = {'WENDYOS_KERNEL_RELEASE_FILE': str(release_file), 'WENDYOS_KERNEL_CONFIG': str(config),
                      'IMAGE_ROOTFS': str(root), 'WENDYOS_CAMERA_LOOPBACK_CHECKER': str(ROOT / 'scripts/check_mesh_kernel_support.py')}
            class D:
                getVar = staticmethod(values.get)
            def run():
                exec(code, {'d': D(), 'bb': BB()})
            run()
            for missing in files:
                with self.subTest(missing=missing):
                    (modules / missing).unlink()
                    with self.assertRaisesRegex(RuntimeError, 'Camera loopback image acceptance failed'):
                        run()
                    (modules / missing).write_bytes(b'fixture module')
            release_file.write_text('7.2.9-wrong-kernel')
            with self.assertRaisesRegex(RuntimeError, 'missing installed module directory'):
                run()

    def test_vm_wiring(self):
        image = (ROOT / 'conf/distro/include/vm-image.inc').read_text()
        self.assertIn('inherit camera-loopback-check', image)
        self.assertIn('v4l2loopback', ' '.join(re.findall(r'^IMAGE_INSTALL:append = "([^"]*)"', image, re.M)).split())
        recipe = (ROOT / 'recipes-kernel/v4l2loopback/v4l2loopback_0.15.4.bb').read_text()
        pattern = re.search(r'^COMPATIBLE_MACHINE = "([^"]*)"', recipe, re.M)[1]
        for arch in ('arm64', 'x86-64'):
            machine = (ROOT / f'conf/machine/vm-{arch}-wendyos.conf').read_text()
            overrides = re.search(r'^MACHINEOVERRIDES =\. "([^"]*)"', machine, re.M)[1].split(':')
            self.assertTrue(any(re.match(pattern, token) for token in overrides))
        append = (ROOT / 'meta-vm-extensions/recipes-kernel/linux/linux-yocto_%.bbappend').read_text()
        self.assertIn('SRC_URI:append:vm-wendyos = " file://camera-loopback.cfg"', append)
        self.assertIn('CONFIG_USB_VIDEO_CLASS=m', (ROOT / 'meta-vm-extensions/recipes-kernel/linux/files/camera-loopback.cfg').read_text())


if __name__ == '__main__':
    unittest.main()
