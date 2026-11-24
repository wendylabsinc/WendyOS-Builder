#!/usr/bin/env python3

import importlib.util
import pathlib
import re
import shutil
import struct
import tempfile
import unittest

MODULE_PATH = pathlib.Path(__file__).with_name("make-jetson-disk-img.py")
SPEC = importlib.util.spec_from_file_location("make_jetson_disk_img", MODULE_PATH)
disk_image = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(disk_image)

# The Jetson Orin Nano NVMe layout of the WendyOS 0.20.2 flashpack, and where
# 1 MiB placement starts each of its partitions, by GPT number. The Wendy CLI
# pins the same file and table (go/internal/cli/tegraflash/t234): the USB flash
# and this script must place every partition on the same sector.
ORIN_NANO_NVME_LAYOUT = (
    pathlib.Path(__file__).with_name("testdata") / "orin-nano-nvme-0.20.2-initrd-flash.xml"
)
ORIN_NANO_NVME_STARTS = {
    3: 2048, 4: 264192, 5: 266240, 6: 331776, 7: 593920, 8: 595968,
    9: 661504, 10: 825344, 11: 827392, 12: 958464, 13: 1122304, 14: 1124352,
    15: 1255424, 1: 2074624, 2: 27240448, 16: 52406272, 17: 52930560,
}
ALIGN_BOUNDARY_ELEMENT = re.compile(r"[ \t]*<align_boundary>[^<]*</align_boundary>\r?\n")
FOUR_MIB_BOUNDARY = "<align_boundary> 4194304 </align_boundary>"
SIXTEEN_KIB_BOUNDARY = "<align_boundary> 16384 </align_boundary>"


class JetsonDiskImageTests(unittest.TestCase):
    def fixture(self, *, fill=False, boundary=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = pathlib.Path(tmp.name)
        (root / "rootfs.img").write_bytes(b"rootfs")
        attribute = "0x808" if fill else "8"
        align = "" if boundary is None else f"<align_boundary>{boundary}</align_boundary>"
        (root / "flash.xml.in").write_text(f"""<?xml version="1.0"?>
<partition_layout version="01.00.0000">
  <device type="external" instance="0" sector_size="512" num_sectors="20000">
    <partition name="wrong" id="1" type="data"><allocation_policy>sequential</allocation_policy><size>1048576</size><allocation_attribute>8</allocation_attribute></partition>
  </device>
  <device type="sdcard" instance="0" sector_size="512" num_sectors="20000">
    <partition name="APP" id="1" type="data"><allocation_policy>sequential</allocation_policy><size>1048576</size><allocation_attribute>8</allocation_attribute><filename>rootfs.img</filename></partition>
    <partition name="data" id="2" type="data"><allocation_policy>sequential</allocation_policy><size>1048576</size><allocation_attribute>{attribute}</allocation_attribute>{align}</partition>
  </device>
</partition_layout>""")
        return root

    def orin_nano_partitions(self, edit=None):
        text = ORIN_NANO_NVME_LAYOUT.read_text()
        self.assertEqual(
            (text.count(SIXTEEN_KIB_BOUNDARY), text.count(FOUR_MIB_BOUNDARY),
             len(ALIGN_BOUNDARY_ELEMENT.findall(text))),
            (3, 2, 5),
        )
        if edit is not None:
            text = edit(text)
            self.assertNotIn(FOUR_MIB_BOUNDARY, text)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = pathlib.Path(tmp.name)
        for name in ("boot.img", "tegra234-p3768-0000+p3767-0005-nv-super.dtb", "esp.img",
                     "wendyos-image.ext4", "config-partition.fat32.img"):
            (root / name).write_bytes(name.encode())
        (root / "initrd-flash.xml").write_text(text)
        _, partitions = disk_image.parse_layout(root, "initrd-flash.xml", "external")
        return partitions

    def gpt_entries(self, image, header_lba):
        with image.open("rb") as disk:
            disk.seek(header_lba * 512)
            header = disk.read(92)
            self.assertEqual(header[:8], b"EFI PART")
            entries_lba, count, size = struct.unpack_from("<QII", header, 72)
            disk.seek(entries_lba * 512)
            table = disk.read(count * size)
        entries = {}
        for index in range(count):
            entry = table[index * size:(index + 1) * size]
            if any(entry[:16]):
                entries[index + 1] = struct.unpack_from("<QQ", entry, 32)
        return entries

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

    def test_orin_nano_config_and_data_start_on_their_align_boundary(self):
        partitions = self.orin_nano_partitions()
        self.assertEqual(
            {part["id"]: part["_start_lba"] for part in partitions},
            {**ORIN_NANO_NVME_STARTS, 16: 52412416, 17: 52936704},
        )
        self.assertEqual([part["name"] for part in partitions[-2:]], ["config", "data"])
        for part in partitions[-2:]:
            self.assertEqual(part["_start_lba"] * 512 % 4194304, 0)
        self.assertEqual(partitions[-1]["_end_lba"], 52936704 + 1048576 - 1)

    def test_orin_nano_without_a_4mib_align_boundary_is_placed_as_before(self):
        edits = {
            "no align_boundary": lambda text: ALIGN_BOUNDARY_ELEMENT.sub("", text),
            "only NVIDIA's 16 KiB": lambda text: text.replace(FOUR_MIB_BOUNDARY, ""),
            "16 KiB on config and data too":
                lambda text: text.replace(FOUR_MIB_BOUNDARY, SIXTEEN_KIB_BOUNDARY),
            "16 KiB on every partition":
                lambda text: ALIGN_BOUNDARY_ELEMENT.sub("", text).replace(
                    "</allocation_policy>", "</allocation_policy>" + SIXTEEN_KIB_BOUNDARY),
        }
        for name, edit in edits.items():
            with self.subTest(name):
                partitions = self.orin_nano_partitions(edit)
                self.assertEqual(
                    {part["id"]: part["_start_lba"] for part in partitions},
                    ORIN_NANO_NVME_STARTS,
                )
                self.assertEqual(partitions[-1]["_end_lba"], 52930560 + 1048576 - 1)

    def test_align_boundary_values(self):
        starts = {
            "4194304": 8192, " 4194304 ": 8192, "0x400000": 8192, "8388608": 16384,
            "2097152": 4096, "1048576": 4096, "16384": 4096, "512": 4096,
            "": 4096, "  ": 4096,
        }
        for boundary, start in starts.items():
            with self.subTest(boundary=boundary):
                _, partitions = disk_image.parse_layout(
                    self.fixture(boundary=boundary), "flash.xml.in", "sdcard"
                )
                self.assertEqual([part["_start_lba"] for part in partitions], [2048, start])

    def test_invalid_align_boundary_fails_closed(self):
        for boundary in ("0", "0x0", "256", "513", "1000", "4194303", "3145728", "6291456",
                         "-4194304", "4 MiB", "4194304.5"):
            with self.subTest(boundary=boundary):
                with self.assertRaisesRegex(
                    ValueError, "partition data has invalid align_boundary"
                ):
                    disk_image.parse_layout(
                        self.fixture(boundary=boundary), "flash.xml.in", "sdcard"
                    )

    def test_fill_to_end_on_align_boundary_uses_last_usable_sector(self):
        sectors, partitions = disk_image.parse_layout(
            self.fixture(fill=True, boundary="4194304"), "flash.xml.in", "sdcard"
        )
        self.assertEqual(partitions[-1]["_start_lba"], 8192)
        self.assertEqual(partitions[-1]["_end_lba"], sectors - 34)

    def test_align_boundary_past_the_device_end_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "exceeds device capacity"):
            disk_image.parse_layout(
                self.fixture(boundary="16777216"), "flash.xml.in", "sdcard"
            )

    @unittest.skipUnless(shutil.which("sgdisk"), "sgdisk is not installed")
    def test_sgdisk_writes_the_aligned_starts(self):
        root = self.fixture(boundary="4194304")
        sectors, partitions = disk_image.parse_layout(root, "flash.xml.in", "sdcard")
        image = root / "disk.img"
        with image.open("wb") as disk:
            disk.truncate(sectors * 512)
        disk_image.create_gpt(image, partitions)
        for header_lba in (1, sectors - 1):
            self.assertEqual(
                self.gpt_entries(image, header_lba),
                {1: (2048, 4095), 2: (8192, 10239)},
            )


if __name__ == "__main__":
    unittest.main()
