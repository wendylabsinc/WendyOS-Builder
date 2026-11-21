"""SensorLink image acceptance must reject absent drivers and stale module trees."""

import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('check_sensor_loopback_support.py')
ROOT = SCRIPT.parent.parent
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location('sensor_loopback_check', SCRIPT)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
GATED_IMAGES = tuple(f'conf/distro/include/{family}-image.inc'
                     for family in ('qcom', 'rpi', 'vm', 'qemu'))


class SensorLoopbackImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.release = '7.2.0-wendyos-iq9'
        self.modules = self.root / 'usr/lib/modules' / self.release
        self.modules.mkdir(parents=True)
        self.config = {
            'CONFIG_VIDEO_DEV': 'm',
            'CONFIG_VIDEOBUF2_VMALLOC': 'm',
            'CONFIG_SND_ALOOP': 'm',
        }
        self.files = {
            'extra/v4l2loopback.ko.xz': ['kernel/media/videodev.ko.xz'],
            'kernel/media/videodev.ko.xz': [],
            'kernel/media/videobuf2-vmalloc.ko.xz': [],
            'kernel/sound/snd-aloop.ko.xz': ['kernel/sound/snd-pcm.ko.xz'],
            'kernel/sound/snd-pcm.ko.xz': ['kernel/sound/snd.ko.xz'],
            'kernel/sound/snd.ko.xz': [],
        }
        self.write_modules()

    def write_modules(self):
        for name in self.files:
            path = self.modules / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture module content')
        (self.modules / 'modules.dep').write_text(''.join(
            f'{name}: {" ".join(deps)}\n' for name, deps in self.files.items()))

    def validate(self):
        return check.validate(self.config, self.root, self.release)

    def test_complete_image_passes(self):
        self.assertEqual(self.validate(), [])

    def test_enabled_audio_without_installed_package_fails(self):
        (self.modules / 'kernel/sound/snd-aloop.ko.xz').unlink()
        self.assertTrue(any('snd-aloop.ko' in error for error in self.validate()))

    def test_external_driver_is_required_even_with_builtin_media(self):
        self.config['CONFIG_VIDEO_DEV'] = 'y'
        self.config['CONFIG_VIDEOBUF2_VMALLOC'] = 'y'
        del self.files['extra/v4l2loopback.ko.xz']
        self.write_modules()
        self.assertTrue(any('external module v4l2loopback' in error for error in self.validate()))

    def test_external_driver_file_must_exist(self):
        (self.modules / 'extra/v4l2loopback.ko.xz').unlink()
        self.assertTrue(any('v4l2loopback.ko' in error for error in self.validate()))

    def test_external_driver_dependency_must_exist(self):
        # The dependency must be checked even if the effective config claims
        # V4L2 is built in; modules.dep describes what this actual .ko needs.
        self.config['CONFIG_VIDEO_DEV'] = 'y'
        (self.modules / 'kernel/media/videodev.ko.xz').unlink()
        self.assertTrue(any('videodev.ko' in error for error in self.validate()))

    def test_transitive_audio_dependency_must_exist(self):
        (self.modules / 'kernel/sound/snd.ko.xz').unlink()
        self.assertTrue(any('snd.ko' in error for error in self.validate()))

    def test_wrong_kernel_modules_do_not_satisfy_image(self):
        self.release = '7.2.0-other-kernel'
        self.assertTrue(any('missing installed module directory' in error for error in self.validate()))

    def test_disabled_kernel_features_fail_even_with_module_files(self):
        for symbol in self.config:
            with self.subTest(symbol=symbol):
                config = {key: value for key, value in self.config.items() if key != symbol}
                self.assertTrue(any(symbol in error for error in check.validate(config, self.root, self.release)))

    def test_builtin_sound_core_passes(self):
        # Pi 4/5: the USB gadget fragment builds the sound core in, so snd-aloop has no deps.
        self.release = '6.18.33-v8-16k-wendy-mesh2'
        self.modules = self.root / 'lib/modules' / self.release
        self.config = {
            'CONFIG_SND': 'y',
            'CONFIG_SND_ALOOP': 'm',
            'CONFIG_VIDEO_DEV': 'm',
            'CONFIG_VIDEOBUF2_VMALLOC': 'm',
        }
        media = 'kernel/drivers/media'
        self.files = {
            'extra/v4l2loopback.ko.xz': [f'{media}/v4l2-core/videodev.ko.xz', f'{media}/mc/mc.ko.xz'],
            f'{media}/v4l2-core/videodev.ko.xz': [f'{media}/mc/mc.ko.xz'],
            f'{media}/mc/mc.ko.xz': [],
            f'{media}/common/videobuf2/videobuf2-vmalloc.ko.xz': [
                f'{media}/common/videobuf2/videobuf2-memops.ko.xz',
                f'{media}/common/videobuf2/videobuf2-common.ko.xz',
                f'{media}/mc/mc.ko.xz'],
            f'{media}/common/videobuf2/videobuf2-memops.ko.xz': [
                f'{media}/common/videobuf2/videobuf2-common.ko.xz', f'{media}/mc/mc.ko.xz'],
            f'{media}/common/videobuf2/videobuf2-common.ko.xz': [f'{media}/mc/mc.ko.xz'],
            'kernel/sound/drivers/snd-aloop.ko.xz': [],
        }
        self.write_modules()
        self.assertEqual(self.validate(), [])

    def test_audio_must_remain_modular(self):
        self.config['CONFIG_SND_ALOOP'] = 'y'
        self.assertTrue(any('CONFIG_SND_ALOOP must be modular' in error for error in self.validate()))

    def test_cli_fails_for_reported_missing_drivers(self):
        config = self.root / '.config'
        config.write_text(''.join(f'{key}={value}\n' for key, value in self.config.items()))
        (self.modules / 'extra/v4l2loopback.ko.xz').unlink()
        (self.modules / 'kernel/sound/snd-aloop.ko.xz').unlink()
        result = subprocess.run([sys.executable, str(SCRIPT), '--config', str(config),
                                 '--rootfs', str(self.root), '--kernel-release', self.release],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('v4l2loopback.ko', result.stderr)
        self.assertIn('snd-aloop.ko', result.stderr)


class SensorLoopbackBuildContractTests(unittest.TestCase):
    def test_every_gated_image_installs_both_drivers(self):
        for path in GATED_IMAGES:
            with self.subTest(image=path):
                image = (ROOT / path).read_text()
                self.assertIn('inherit sensor-loopback-check', image)
                installed = re.findall(r'^IMAGE_INSTALL:append = "([^"]*)"', image, re.M)
                packages = ' '.join(installed).split()
                self.assertIn('v4l2loopback', packages)
                self.assertIn('kernel-module-snd-aloop', packages)
        gate = (ROOT / 'classes/sensor-loopback-check.bbclass').read_text()
        self.assertIn('do_rootfs[postfuncs] += "wendyos_check_sensor_loopback_rootfs"', gate)
        self.assertIn('do_rootfs[depends] += "${WENDYOS_KERNEL_OUTPUTS_DEPENDS}"', gate)
        checksums = re.search(r'^do_rootfs\[file-checksums\] \+= "([^"]*)"', gate, re.M)[1]
        self.assertIn('${WENDYOS_SENSOR_LOOPBACK_CHECKER}:True', checksums)
        self.assertIn('${WENDYOS_SENSOR_LOOPBACK_KERNEL_CHECKER}:True', checksums)

    def test_shared_recipe_and_visible_kconfig_selectors(self):
        recipe = ROOT / 'recipes-kernel/v4l2loopback/v4l2loopback_0.15.4.bb'
        self.assertIn('COMPATIBLE_MACHINE = "(tegra|qcom-wendyos|rpi|vm-wendyos|qemuall)"', recipe.read_text())
        self.assertFalse((ROOT / 'meta-tegra-extensions-jp7/recipes-kernel/v4l2loopback' / recipe.name).exists())
        fragment = ROOT / 'meta-qcom-extensions/recipes-kernel/linux/linux-qcom-next/sensor-loopback.cfg'
        config = check.read_config(fragment)
        self.assertEqual(config['CONFIG_MEDIA_USB_SUPPORT'], 'y')
        self.assertEqual(config['CONFIG_USB_VIDEO_CLASS'], 'm')
        self.assertEqual(config['CONFIG_SOUND'], 'm')
        self.assertEqual(config['CONFIG_SND'], 'm')
        self.assertEqual(config['CONFIG_MEDIA_SUPPORT'], 'm')

    def test_virtual_images_require_loopback_modules(self):
        recipe = (ROOT / 'recipes-kernel/v4l2loopback/v4l2loopback_0.15.4.bb').read_text()
        compatible = re.search(r'^COMPATIBLE_MACHINE = "([^"]+)"', recipe, re.M)[1]
        for family, override in [('vm', 'vm-wendyos'), ('qemu', 'qemuall')]:
            with self.subTest(family=family):
                self.assertIsNotNone(re.match(compatible, override))
                image = (ROOT / f'conf/distro/include/{family}-image.inc').read_text()
                packages = ' '.join(re.findall(r'^IMAGE_INSTALL:append = "([^"]*)"', image, re.M)).split()
                self.assertIn('v4l2loopback', packages)
                append = (ROOT / f'meta-{family}-extensions/recipes-kernel/linux/linux-yocto_%.bbappend').read_text()
                self.assertIn('require recipes-kernel/linux/virtual-loopback.inc', append)
        fragment = check.read_config(ROOT / 'recipes-kernel/linux/virtual-loopback/virtual-loopback.cfg')
        self.assertEqual(fragment['CONFIG_SND_ALOOP'], 'm')
        # Media and sound stay at each board's own setting.
        for symbol in ('CONFIG_MEDIA_SUPPORT', 'CONFIG_SOUND', 'CONFIG_SND'):
            self.assertNotIn(symbol, fragment)
        self.assertEqual(fragment['CONFIG_USB_VIDEO_CLASS'], 'm')

    def test_virtual_loopback_gate_accepts_builtin_or_modular_and_rejects_missing(self):
        recipe = ROOT / 'recipes-kernel/linux/virtual-loopback.inc'
        body = re.search(r'^wendyos_check_virtual_loopback\(\) \{\n(.*?)^\}',
                         recipe.read_text(), re.M | re.S)[1]
        symbols = ('CONFIG_VIDEO_DEV', 'CONFIG_VIDEOBUF2_VMALLOC')
        with tempfile.TemporaryDirectory() as tmp:
            script = body.replace('${B}', tmp).replace('${MACHINE}', 'vm-arm64-wendyos')
            script = 'bbfatal() { echo "$*" >&2; exit 1; }\n' + script
            for value in ('y', 'm'):
                for missing in [None, *symbols, 'CONFIG_SND_ALOOP']:
                    with self.subTest(value=value, missing=missing):
                        (Path(tmp) / '.config').write_text(''.join(
                            f'{key}={value}\n' for key in symbols if key != missing)
                            + ('' if missing == 'CONFIG_SND_ALOOP' else 'CONFIG_SND_ALOOP=m\n'))
                        result = subprocess.run(['sh', '-eu'], input=script, text=True, capture_output=True)
                        self.assertEqual(result.returncode == 0, missing is None, result.stderr)
                        if missing:
                            self.assertIn(missing, result.stderr)
            (Path(tmp) / '.config').write_text(''.join(f'{key}=y\n' for key in symbols) + 'CONFIG_SND_ALOOP=y\n')
            result = subprocess.run(['sh', '-eu'], input=script, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('CONFIG_SND_ALOOP must be modular', result.stderr)
            (Path(tmp) / '.config').unlink()
            result = subprocess.run(['sh', '-eu'], input=script, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('missing resolved kernel config', result.stderr)

    def test_resolved_kernel_gate_rejects_dropped_features(self):
        recipe = ROOT / 'meta-qcom-extensions/recipes-kernel/linux/linux-qcom-next_%.bbappend'
        body = re.search(r'^wendyos_check_sensor_loopback\(\) \{\n(.*?)^\}',
                         recipe.read_text(), re.M | re.S)[1]
        values = {'CONFIG_VIDEO_DEV': 'm', 'CONFIG_VIDEOBUF2_VMALLOC': 'm', 'CONFIG_SND_ALOOP': 'm'}
        with tempfile.TemporaryDirectory() as tmp:
            script = body.replace('${B}', tmp).replace('${MACHINE}', 'iq-9075-evk-wendyos')
            script = 'bbfatal() { echo "$*" >&2; exit 1; }\n' + script
            for missing in [None, *values]:
                with self.subTest(missing=missing):
                    (Path(tmp) / '.config').write_text(''.join(
                        f'{key}={value}\n' for key, value in values.items() if key != missing))
                    result = subprocess.run(['sh', '-eu'], input=script, text=True, capture_output=True)
                    self.assertEqual(result.returncode == 0, missing is None, result.stderr)
                    if missing:
                        self.assertIn(missing, result.stderr)


if __name__ == '__main__':
    unittest.main()
