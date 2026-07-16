#!/usr/bin/env python3

import importlib.util
import pathlib
import tempfile
import unittest

MODULE_PATH = pathlib.Path(__file__).with_name("make-jetson-disk-img.py")
SPEC = importlib.util.spec_from_file_location("make_jetson_disk_img", MODULE_PATH)
disk_image = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(disk_image)


class JetsonDiskImageTests(unittest.TestCase):
    def fixture(self, *, fill=False):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = pathlib.Path(tmp.name)
        (root / "rootfs.img").write_bytes(b"rootfs")
        attribute = "0x808" if fill else "8"
        (root / "flash.xml.in").write_text(f"""<?xml version="1.0"?>
<partition_layout version="01.00.0000">
  <device type="external" instance="0" sector_size="512" num_sectors="20000">
    <partition name="wrong" id="1" type="data"><allocation_policy>sequential</allocation_policy><size>1048576</size><allocation_attribute>8</allocation_attribute></partition>
  </device>
  <device type="sdcard" instance="0" sector_size="512" num_sectors="20000">
    <partition name="APP" id="1" type="data"><allocation_policy>sequential</allocation_policy><size>1048576</size><allocation_attribute>8</allocation_attribute><filename>rootfs.img</filename></partition>
    <partition name="data" id="2" type="data"><allocation_policy>sequential</allocation_policy><size>1048576</size><allocation_attribute>{attribute}</allocation_attribute></partition>
  </device>
</partition_layout>""")
        return root

    def test_sdcard_layout_is_selected_and_aligned(self):
        sectors, partitions = disk_image.parse_layout(
            self.fixture(), "flash.xml.in", "sdcard"
        )
        self.assertEqual(sectors, 20000)
        self.assertEqual([part["name"] for part in partitions], ["APP", "data"])
        self.assertEqual(partitions[0]["_start_lba"], 2048)
        self.assertEqual(partitions[1]["_start_lba"], 4096)

    def test_fill_to_end_uses_last_usable_sector(self):
        sectors, partitions = disk_image.parse_layout(
            self.fixture(fill=True), "flash.xml.in", "sdcard"
        )
        self.assertEqual(partitions[-1]["_end_lba"], sectors - 34)

    def test_missing_partition_image_fails_closed(self):
        root = self.fixture()
        (root / "rootfs.img").unlink()
        with self.assertRaisesRegex(ValueError, "missing or not regular"):
            disk_image.parse_layout(root, "flash.xml.in", "sdcard")

    def test_known_agx_alignment_matches_sgdisk_reference(self):
        partitions = [
            {"id": 3, "name": "A_kernel", "size_bytes": 262144 * 512, "fill_to_end": False},
            {"id": 4, "name": "A_kernel-dtb", "size_bytes": 1536 * 512, "fill_to_end": False},
            {"id": 5, "name": "A_reserved", "size_bytes": 64768 * 512, "fill_to_end": False},
        ]
        disk_image.place_partitions(partitions, 124321792)
        self.assertEqual(
            [part["_start_lba"] for part in partitions],
            [2048, 264192, 266240],
        )


if __name__ == "__main__":
    unittest.main()
