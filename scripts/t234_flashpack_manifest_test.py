#!/usr/bin/env python3

import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import t234_flashpack_manifest as manifest  # noqa: E402


class ManifestV2Tests(unittest.TestCase):
    def fixture(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = pathlib.Path(tmp.name)
        for directory in ("stage1", "stage2/flash", "stage2/flashpkg/logs"):
            (root / directory).mkdir(parents=True, exist_ok=True)
        rcm_files = ["br.bct", "mb1.bin", "psc.bin", "mb1.bct", "mem.bct", "blob.bin"]
        (root / "stage1/rcmbootcmd.txt").write_text(
            "tegrarcm --download bct_br br.bct --download mb1 mb1.bin "
            "--download psc_bl1 psc.bin --download bct_mb1 mb1.bct\n"
            "tegrarcm --download bct_mem mem.bct --download blob blob.bin\n"
        )
        for name in rcm_files:
            (root / "stage1" / name).write_bytes(name.encode())
        (root / "stage2/flash/rootfs.img").write_bytes(b"rootfs")
        (root / "stage2/flash/config-partition.fat32.img").write_bytes(b"config")
        (root / "stage2/flash/initrd-flash.xml").write_text("""<?xml version="1.0"?>
<partition_layout version="01.00.0000"><device type="spi" instance="0" sector_size="512">
<partition name="boot" id="1" type="data"><allocation_policy>sequential</allocation_policy><filesystem_type>basic</filesystem_type><size>4096</size><allocation_attribute>8</allocation_attribute><filename>bootloader-not-staged.img</filename></partition>
</device><device type="external" instance="0" sector_size="512">
<partition name="APP" id="1" type="data"><allocation_policy>sequential</allocation_policy><filesystem_type>basic</filesystem_type><size>4096</size><allocation_attribute>8</allocation_attribute><filename>rootfs.img</filename></partition>
<partition name="config" id="2" type="data"><allocation_policy>sequential</allocation_policy><filesystem_type>basic</filesystem_type><size>4096</size><allocation_attribute>8</allocation_attribute><filename>config-partition.fat32.img</filename></partition>
</device><device type="sdmmc_user" instance="3" sector_size="512">
<partition name="APP" id="1" type="data"><allocation_policy>sequential</allocation_policy><filesystem_type>basic</filesystem_type><size>4096</size><allocation_attribute>8</allocation_attribute><filename>rootfs.img</filename></partition>
<partition name="config" id="2" type="data"><allocation_policy>sequential</allocation_policy><filesystem_type>basic</filesystem_type><size>4096</size><allocation_attribute>8</allocation_attribute><filename>config-partition.fat32.img</filename></partition>
</device></partition_layout>""")
        (root / "stage2/flashpkg.ext4").touch()
        (root / "stage2/flashpkg.ext4").chmod(0o644)
        with (root / "stage2/flashpkg.ext4").open("r+b") as stream:
            stream.truncate(128 << 20)
        (root / "stage2/flashpkg/status").write_text("PENDING")
        return root

    def generate(self, root, **overrides):
        args = dict(version="0.18.0", device="jetson-orin-nano", storage="nvme",
                    machine="jetson-orin-nano-devkit-nvme-wendyos",
                    board_id="3767", board_sku="0005",
                    board_fab="300", board_rev="", chip_sku="00:00:00:D3",
                    rootfs_device="nvme0n1", boot_device_type="spi",
                    rootfs_image="rootfs.img")
        args.update(overrides)
        return manifest.generate(root, **args)

    def test_schema_v2_identity_and_all_consumed_files(self):
        result = self.generate(self.fixture())
        self.assertEqual(result["schema"], 2)
        self.assertEqual(result["protocol"], "usb-mass-storage-v1")
        self.assertEqual(result["usb_product_id"], "0x7023")
        self.assertEqual(result["target"], {
            "device": "jetson-orin-nano", "storage": "nvme",
            "module_id": "3767", "module_sku": "0005",
            "carrier_id": "3768", "carrier_sku": "0000",
        })
        for path in ("stage2/flashpkg.ext4", "stage2/flash/initrd-flash.xml",
                     "stage2/flash/config-partition.fat32.img", "stage2/flash/rootfs.img"):
            self.assertIn(path, result["files"])

    def test_wrong_sku_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match target"):
            self.generate(self.fixture(), board_sku="0003")

    def test_wrong_machine_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match supported"):
            self.generate(self.fixture(), machine="custom-carrier-machine")

    def test_missing_partition_image_is_rejected(self):
        root = self.fixture()
        (root / "stage2/flash/rootfs.img").unlink()
        with self.assertRaisesRegex(ValueError, "required regular file is missing"):
            self.generate(root)

    def test_host_generated_gpt_partitions_are_not_required(self):
        # The protective MBR and both GPT copies are generated by the host CLI
        # (tegraflash/t234/plan.go skips these types), not shipped in the
        # flashpack. The layout still lists them with a <filename>, so validation
        # must skip them rather than demand a staged file. Regression: the real
        # NVIDIA layout failed with "required regular file is missing:
        # stage2/flash/gpt_secondary_3_0.bin".
        root = self.fixture()
        xml_path = root / "stage2/flash/initrd-flash.xml"
        layout = xml_path.read_text().replace(
            '<device type="external" instance="0" sector_size="512">',
            '<device type="external" instance="0" sector_size="512">'
            '<partition name="secondary_gpt" type="secondary_gpt">'
            '<allocation_policy>sequential</allocation_policy><size>4096</size>'
            '<allocation_attribute>8</allocation_attribute>'
            '<filename>gpt_secondary_3_0.bin</filename></partition>',
        )
        xml_path.write_text(layout)
        # gpt_secondary_3_0.bin is intentionally never created in stage2/flash.
        result = self.generate(root)
        self.assertEqual(result["schema"], 2)
        self.assertNotIn("stage2/flash/gpt_secondary_3_0.bin", result["files"])

    def test_agx_storage_specific_identity(self):
        root = self.fixture()
        result = self.generate(root, device="jetson-agx-orin", storage="nvme",
                               machine="jetson-agx-orin-devkit-nvme-wendyos",
                               board_id="3701", board_sku="0005")
        self.assertEqual(result["target"]["carrier_id"], "3737")

        emmc = self.generate(root, device="jetson-agx-orin", storage="emmc",
                             machine="jetson-agx-orin-devkit-emmc-wendyos",
                             board_id="3701", board_sku="0005",
                             rootfs_device="mmcblk0")
        self.assertEqual(emmc["target"]["storage"], "emmc")
        self.assertEqual(emmc["rootfs_device"], "mmcblk0")


if __name__ == "__main__":
    unittest.main()
