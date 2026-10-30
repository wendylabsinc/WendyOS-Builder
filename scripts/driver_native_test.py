"""Check device selection and native module closure staging."""

import hashlib
import json
from pathlib import Path
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from scripts.resolve_driver_manifest import resolve
from scripts.stage_native_driver import stage


ROOT = Path(__file__).resolve().parents[1]


class VariantTests(unittest.TestCase):
    def test_iq_uses_native_modules_and_nan_firmware(self):
        manifest = json.loads((ROOT / "drivers/intel-be202/driver.json").read_text())
        for device in ("dragonwing-iq-8275", "dragonwing-iq-9075"):
            resolved = resolve(manifest, device)
            self.assertEqual(resolved["build"]["kind"], "kernel-modules")
            self.assertEqual(resolved["patches"], [])
            self.assertEqual({entry["path"] for entry in resolved["firmware"]}, {
                "iwlwifi-gl-c0-fm-c0-c106.ucode", "iwlwifi-gl-c0-fm-c0.pnvm",
                "LICENCE.iwlwifi_firmware",
            })
            # Keep IQ below this kernel's c106 API ceiling, with the same
            # NAN-capable firmware and notice already pinned for Jetson.
            for entry in resolved["firmware"]:
                self.assertIn(entry, manifest["firmware"])
            self.assertTrue(resolved["source"]["devkit"])
        for device in ("jetson-agx-thor", "jetson-orin-nano", "raspberry-pi-5"):
            resolved = resolve(manifest, device)
            self.assertEqual(resolved["build"]["kind"], "backport-iwlwifi")
            self.assertEqual(resolved["firmware"][0]["path"], "iwlwifi-gl-c0-fm-c0-c107.ucode")
        self.assertEqual(manifest["build"]["kind"], "backport-iwlwifi")

    def test_missing_or_undeclared_identity_is_rejected(self):
        manifest = json.loads((ROOT / "drivers/intel-be202/driver.json").read_text())
        with self.assertRaisesRegex(ValueError, "device ID required"):
            resolve(manifest, "")
        manifest["variants_by_device"]["unknown"] = {"build": {}}
        with self.assertRaisesRegex(ValueError, "devices list"):
            resolve(manifest, "unknown")

    def test_variant_cannot_change_package_identity_or_activation(self):
        for key in ("name", "activation", "modules_load"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                resolve({"devices": ["board"], "variants_by_device": {"board": {key: "bad"}}}, "board")


class NativeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.devkit = self.root / "devkit"
        (self.devkit / "native-modules").mkdir(parents=True)
        (self.devkit / "native-firmware").mkdir()
        (self.devkit / "native-firmware/LICENCE").write_text("redistribution notice")
        self.index = {}
        for name, deps in (("card", ["bus"]), ("bus", []), ("unrelated", [])):
            data = (name + " module").encode()
            (self.devkit / "native-modules" / (name + ".ko")).write_bytes(data)
            self.index[name] = {"file": name + ".ko", "depends": deps,
                                "sha256": hashlib.sha256(data).hexdigest()}
        self.manifest = {"build": {"modules": ["card"], "firmware_from_devkit": True}}
        self.out = self.root / "build/src"

    def run_stage(self):
        (self.devkit / "native-modules/index.json").write_text(json.dumps(self.index))
        stage(self.devkit, self.manifest, self.out)

    def test_dependency_closure_and_notices_are_copied(self):
        self.run_stage()
        self.assertEqual({p.name for p in self.out.iterdir()}, {"card.ko", "bus.ko"})
        self.assertEqual((self.out.parent / "firmware/LICENCE").read_text(), "redistribution notice")

    def test_missing_dependency_fails(self):
        del self.index["bus"]
        with self.assertRaises(KeyError):
            self.run_stage()

    def test_base_image_dependency_is_not_copied(self):
        self.index["bus"] = {"provided_by": "base-image"}
        # A stale binary in the devkit must not make the base marker a payload.
        self.run_stage()
        self.assertEqual({p.name for p in self.out.iterdir()}, {"card.ko"})

    def test_unknown_provider_does_not_silently_skip_dependency(self):
        self.index["bus"] = {"provided_by": "unknown"}
        with self.assertRaises(KeyError):
            self.run_stage()

    def test_corrupt_module_fails(self):
        (self.devkit / "native-modules/card.ko").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.run_stage()

    def test_index_cannot_escape_native_module_directory(self):
        self.index["card"]["file"] = "../outside.ko"
        with self.assertRaisesRegex(ValueError, "unsafe"):
            self.run_stage()


def bitbake_function(path, name):
    source = (ROOT / path).read_text()
    return textwrap.dedent(source.split('python ' + name + '() {\n', 1)[1].split('\n}', 1)[0])


class ImageCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.release = '7.2.0-wendyos-cached'
        self.modules = self.root / 'rootfs/usr/lib/modules' / self.release
        self.modules.mkdir(parents=True)
        # Only deployed/packaged outputs and the rootfs exist, as after an
        # sstate restore into a fresh TMPDIR. There is no kernel build tree.
        config = self.root / 'deployed.config'
        config.write_text('CONFIG_MAC80211=m\nCONFIG_CFG80211=m\n')
        self.release_file = self.root / 'kernel-abiversion'
        self.release_file.write_text(self.release + '\n')
        (self.modules / 'mac80211.ko').write_bytes(b'module fixture')
        (self.modules / 'cfg80211.ko').write_bytes(b'dependency fixture')
        (self.modules / 'modules.dep').write_text('mac80211.ko: cfg80211.ko\ncfg80211.ko:\n')
        self.values = {'WENDYOS_KERNEL_CONFIG': str(config),
                       'WENDYOS_KERNEL_RELEASE_FILE': str(self.release_file),
                       'WENDYOS_NATIVE_DRIVER_CHECKER': str(ROOT / 'scripts/check_mesh_kernel_support.py'),
                       'WENDYOS_DRIVER_BASE_MODULES': 'mac80211 cfg80211',
                       'IMAGE_ROOTFS': str(self.root / 'rootfs')}
        self.code = bitbake_function('classes/native-driver-check.bbclass',
                                    'wendyos_check_native_driver_base')

    def check(self):
        def fatal(message):
            raise ValueError(message)

        # Run the actual checker subprocess, not a mocked successful result.
        exec(self.code, {'d': SimpleNamespace(getVar=self.values.get),
                         'bb': SimpleNamespace(fatal=fatal, note=lambda message: None)})

    def test_cached_outputs_pass_without_kernel_build_tree(self):
        self.check()

    def test_cached_outputs_still_reject_missing_dependency(self):
        (self.modules / 'cfg80211.ko').unlink()
        with self.assertRaisesRegex(ValueError, 'requires missing or invalid module file'):
            self.check()

    def test_other_kernel_modules_cannot_satisfy_cached_release(self):
        self.release_file.write_text('7.2.0-wendyos-other\n')
        with self.assertRaisesRegex(ValueError, 'missing installed module directory'):
            self.check()


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.build = self.root / 'build'
        self.build.mkdir()
        self.deps = {'card': 'helper,mac80211', 'helper': 'bluetooth',
                     'mac80211': 'cfg80211', 'cfg80211': '', 'bluetooth': 'crypto'}
        for name in self.deps:
            (self.build / (name + '.ko')).write_bytes(name.encode())
        (self.build / 'modules.order').write_text(''.join(name + '.o\n' for name in self.deps))
        self.values = {'B': str(self.build), 'STAGING_KERNEL_BUILDDIR': str(self.root / 'shared'),
                       'RECIPE_SYSROOT_NATIVE': str(self.root),
                       'WENDYOS_DRIVER_DEVKIT_MODULES': 'card',
                       'WENDYOS_DRIVER_BASE_MODULES': 'cfg80211 mac80211 bluetooth'}
        self.code = bitbake_function('recipes-kernel/linux/driver-extensions.inc',
                                    'wendyos_export_driver_modules')

    def export(self):
        def fatal(message):
            raise ValueError(message)

        with patch('subprocess.check_output', side_effect=lambda args, **kw: self.deps[Path(args[-1]).stem]):
            exec(self.code, {'d': SimpleNamespace(getVar=self.values.get),
                             'bb': SimpleNamespace(fatal=fatal)})
        return self.root / 'shared/wendyos-driver-modules'

    def test_export_and_stage_stop_at_base_image_boundary(self):
        payload = self.export()
        index = json.loads((payload / 'index.json').read_text())
        self.assertEqual({p.name for p in payload.iterdir()}, {'index.json', 'card.ko', 'helper.ko'})
        self.assertEqual(index['mac80211'], {'provided_by': 'base-image'})
        self.assertEqual(index['bluetooth'], {'provided_by': 'base-image'})
        self.assertNotIn('cfg80211', index)
        devkit = self.root / 'devkit'
        devkit.mkdir()
        payload.rename(devkit / 'native-modules')
        output = self.root / 'output'
        stage(devkit, {'build': {'modules': ['card']}}, output)
        self.assertEqual({p.name for p in output.iterdir()}, {'card.ko', 'helper.ko'})

    def test_unprovided_dependency_cannot_be_omitted(self):
        self.deps['helper'] = 'missing'
        with self.assertRaisesRegex(ValueError, 'expected one built module for missing'):
            self.export()

    def test_module_cannot_belong_to_both_image_and_addon(self):
        self.values['WENDYOS_DRIVER_DEVKIT_MODULES'] = 'card mac80211'
        with self.assertRaisesRegex(ValueError, 'also belong to the base image'):
            self.export()


if __name__ == "__main__":
    unittest.main()
