#!/usr/bin/env python3
"""python3 -m unittest discover -s scripts -p 'mark_fat_volumes_test.py'"""
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mark_fat", ROOT / "recipes-core/images/files/mark-fat-volumes.py")
mark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mark)


class MarkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.image = pathlib.Path(self.tmp.name) / "test.wic"
        with self.image.open("wb") as image:
            image.truncate(8 * 1024 * 1024)
        self.table = {"sectorsize": 512, "unit": "sectors", "partitions": [
            {"start": 2048, "size": 4096}, {"start": 8192, "size": 4096}]}

    def stamp(self, offset, kind):
        boot = bytearray(512)
        boot[510:] = b"\x55\xaa"
        boot[82 if kind == b"FAT32   " else 54:90 if kind == b"FAT32   " else 62] = kind
        with self.image.open("r+b") as image:
            image.seek(offset)
            image.write(boot)

    def test_fat16_and_fat32_only(self):
        self.stamp(2048 * 512, b"FAT16   ")
        self.stamp(8192 * 512, b"FAT32   ")
        self.assertEqual(mark.fat_offsets(self.image, self.table), [1048576, 4194304])
        self.stamp(8192 * 512, b"EXFAT   ")
        self.assertEqual(mark.fat_offsets(self.image, self.table), [1048576])

    def test_validate_all_bounds_before_writing(self):
        self.stamp(2048 * 512, b"FAT16   ")
        self.table["partitions"][1]["size"] = 999999
        with mock.patch.object(mark.subprocess, "check_output", return_value=json.dumps({"partitiontable": self.table})), \
                mock.patch.object(mark.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                mark.mark_image(self.image)
            run.assert_not_called()

    def test_usage_without_image(self):
        result = subprocess.run([sys.executable, str(spec.origin)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stderr)

    def test_reject_device(self):
        with self.assertRaises(ValueError):
            mark.mark_image("/dev/null")

    @unittest.skipUnless(all(shutil.which(tool) for tool in ("sfdisk", "mformat", "mcopy", "mtype")), "requires native sfdisk and mtools")
    def test_real_images_preserve_other_files(self):
        # Exercise both layouts shipped by WendyOS, without mounts or root.
        seed = pathlib.Path(self.tmp.name) / "seed"
        seed.write_text("preserve me")
        for label in ("dos", "gpt"):
            with self.subTest(label=label):
                with self.image.open("wb") as image:
                    image.truncate(8 * 1024 * 1024)
                kind = "6" if label == "dos" else "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
                layout = f"label: {label}\nunit: sectors\n\n" + "".join(
                    f"start={p['start']}, size={p['size']}, type={kind}\n" for p in self.table["partitions"]
                )
                subprocess.run(["sfdisk", "--no-reread", str(self.image)], input=layout, text=True, check=True, capture_output=True)
                targets = [f"{self.image}@@{p['start'] * 512}" for p in self.table["partitions"]]
                for target in targets:
                    subprocess.run(["mformat", "-i", target, "-T", "4096", "::"], check=True)
                    subprocess.run(["mcopy", "-i", target, str(seed), "::/seed"], check=True)
                self.assertEqual(mark.mark_image(self.image), 2)
                self.assertEqual(mark.mark_image(self.image), 2)  # idempotent
                for target in targets:
                    self.assertEqual(subprocess.check_output(["mtype", "-i", target, "::/seed"]), b"preserve me")
                    self.assertEqual(subprocess.check_output(["mtype", "-i", target, "::/.metadata_never_index"]), b"")


if __name__ == "__main__":
    unittest.main()
