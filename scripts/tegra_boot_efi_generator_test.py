"""Run the shipped ESP generator against isolated block-device topologies."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RECIPE_DIR = ROOT / "meta-tegra-extensions/recipes-bsp/tools"
GENERATOR = RECIPE_DIR / "files/wendyos-boot-efi-generator.sh"


class BootEfiGeneratorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.sys = self.root / "sys/dev/block"
        self.sys.mkdir(parents=True)
        self.output = self.root / "generator"
        self.output.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.script = self.root / "generator.sh"
        self.script.write_text(
            GENERATOR.read_text().replace("/sys/dev/block", str(self.sys))
            .replace("@ESPMOUNT@", "/boot/efi")
            .replace("@ESPMOUNTUNIT@", "boot-efi.mount"))
        self.mock("findmnt", 'printf "%s\\n" "$TEST_ROOT_DEVICE"\n')
        self.mock("blkid", '''
[ "$*" = "-p -s TYPE -o value -- $TEST_ESP" ] || exit 9
printf '%s\\n' "${TEST_FSTYPE:-vfat}"
''')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        TEST_ROOT_DEVICE="259:1", TEST_ESP="/dev/nvme0n1p11")

    def mock(self, name, body):
        command = self.bin / name
        command.write_text("#!/bin/sh\n" + body)
        command.chmod(0o755)

    def disk(self, name, partitions):
        disk = self.root / "sys/devices/block" / name
        disk.mkdir(parents=True)
        (disk / "dev").write_text("259:0\n")
        for number, label, major_minor in partitions:
            partition = disk / f"{name}p{number}"
            partition.mkdir()
            (partition / "partition").write_text(f"{number}\n")
            (partition / "uevent").write_text(
                f"DEVTYPE=partition\nDEVNAME={name}p{number}\nPARTNAME={label}\n")
            (self.sys / major_minor).symlink_to(partition)

    def run_generator(self):
        return subprocess.run(["sh", str(self.script), str(self.output)],
                              env=self.env, text=True, capture_output=True, check=False)

    def assert_mount(self, expected):
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        mount = self.output / "boot-efi.mount"
        self.assertIn(f"What={expected}\n", mount.read_text())
        self.assertIn("Before=local-fs.target\n", mount.read_text())
        self.assertIn("Where=/boot/efi\nType=vfat\n", mount.read_text())
        self.assertEqual((self.output / "local-fs.target.wants/boot-efi.mount").resolve(), mount)
        self.assertNotIn("by-partlabel", mount.read_text())

    def assert_rejected(self, message):
        result = self.run_generator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertEqual(list(self.output.iterdir()), [], "failure must not generate a mount")

    def test_agx_nvme_ignores_duplicate_emmc_labels_on_both_root_slots(self):
        self.disk("mmcblk0", [(1, "APP", "179:1"), (10, "esp", "179:10")])
        self.disk("nvme0n1", [(1, "APP", "259:1"), (2, "APP_b", "259:2"),
                             (11, "esp", "259:11"), (14, "esp_alt", "259:14")])
        for root_device in ("259:1", "259:2"):
            with self.subTest(root_device=root_device):
                self.env["TEST_ROOT_DEVICE"] = root_device
                self.assert_mount("/dev/nvme0n1p11")

    def test_nano_and_thor_follow_renumbered_nvme_and_partition_layouts(self):
        for name, esp_number, label in (("nvme1n1", 11, "esp"),
                                       ("nvme3n2", 12, "UEFI-ESP")):
            with self.subTest(name=name, esp_number=esp_number, label=label):
                # Independent sysfs fixtures prevent accidentally relying on an
                # NVMe controller index or a board-specific ESP partition number.
                major = 260 if name == "nvme1n1" else 261
                self.disk(name, [(2, "APP_b", f"{major}:2"),
                                 (esp_number, label, f"{major}:{esp_number}")])
                self.env.update(TEST_ROOT_DEVICE=f"{major}:2",
                                TEST_ESP=f"/dev/{name}p{esp_number}")
                self.assert_mount(f"/dev/{name}p{esp_number}")

    def test_emmc_and_sd_boot_ignore_other_disks(self):
        self.disk("nvme0n1", [(1, "APP", "259:1"), (11, "esp", "259:11")])
        for index in (0, 1):
            with self.subTest(index=index):
                name = f"mmcblk{index}"
                minor = 32 * index
                self.disk(name, [(1, "APP", f"179:{minor + 1}"),
                                 (10, "esp", f"179:{minor + 10}")])
                self.env.update(TEST_ROOT_DEVICE=f"179:{minor + 1}", TEST_ESP=f"/dev/{name}p10")
                self.assert_mount(f"/dev/{name}p10")

    def test_missing_esp_does_not_use_other_disks_or_esp_alt(self):
        self.disk("nvme0n1", [(1, "APP", "259:1"), (14, "esp_alt", "259:14")])
        self.disk("mmcblk0", [(10, "esp", "179:10")])
        self.assert_rejected("no EFI partition")

    def test_multiple_primary_esps_are_rejected(self):
        self.disk("nvme0n1", [(1, "APP", "259:1"), (11, "esp", "259:11"),
                             (14, "esp", "259:14")])
        self.assert_rejected("multiple EFI partitions")

    def test_different_supported_labels_on_same_disk_are_ambiguous(self):
        self.disk("nvme0n1", [(1, "APP", "259:1"), (11, "esp", "259:11"),
                             (12, "UEFI-ESP", "259:12")])
        self.assert_rejected("multiple EFI partitions")

    def test_non_fat_esp_is_rejected(self):
        self.disk("nvme0n1", [(1, "APP", "259:1"), (11, "esp", "259:11")])
        self.env["TEST_FSTYPE"] = "ext4"
        self.assert_rejected("expected vfat")

    def test_unreadable_esp_is_rejected(self):
        self.disk("nvme0n1", [(1, "APP", "259:1"), (11, "esp", "259:11")])
        self.mock("blkid", "exit 2\n")
        self.assert_rejected("cannot probe")

    @unittest.skipUnless(shutil.which("systemd-analyze"), "systemd-analyze requires Linux")
    def test_generated_mount_loads_in_systemd(self):
        self.disk("nvme0n1", [(1, "APP", "259:1"), (11, "esp", "259:11")])
        self.assert_mount("/dev/nvme0n1p11")
        result = subprocess.run(
            ["systemd-analyze", "--generators=no", "verify",
             str(self.output / "boot-efi.mount")],
            text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_overlay_and_device_mapper_roots_are_rejected(self):
        for device in ("0:34", "253:0"):
            with self.subTest(device=device):
                self.env["TEST_ROOT_DEVICE"] = device
                # A non-partition sysfs object, as for dm-0, is insufficient
                # evidence to choose one of its possibly many underlying disks.
                path = self.root / "sys/devices/virtual/block" / device
                path.mkdir(parents=True)
                (self.sys / device).symlink_to(path)
                self.assert_rejected("not a disk partition")

    def test_unknown_or_ambiguous_root_device_is_rejected(self):
        for device in ("", "259:1\n259:2", "not-a-device", "259:1:2"):
            with self.subTest(device=device):
                self.env["TEST_ROOT_DEVICE"] = device
                self.assert_rejected("invalid root device number")


if __name__ == "__main__":
    unittest.main()
