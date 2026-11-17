"""Check the /dev/wendyos/boot link: the rule, the root-disk answer behind it, the fstabs."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "recipes-support/data-device/files"
HELPER = FILES / "root-disk-part"
RULE = FILES / "99-wendyos-boot.rules"
FSTABS = ROOT / "recipes-core/base-files/files"
PI_PARTITIONS = ("boot", "config", "rootfsA", "rootfsB", "data")


def udevadm_can_verify():
    return bool(shutil.which("udevadm")) and subprocess.run(
        ["udevadm", "verify", "--help"], capture_output=True, check=False).returncode == 0


class BootLinkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.sys = self.root / "sys"
        (self.sys / "dev/block").mkdir(parents=True)
        findmnt = self.root / "bin/findmnt"
        findmnt.parent.mkdir()
        findmnt.write_text('#!/bin/sh\n[ "$*" = "-nr -o MAJ:MIN --target /" ] || exit 9\n'
                           'printf \'%s\\n\' "$TEST_ROOT_DEVICE"\n')
        findmnt.chmod(0o755)

    def disk(self, name, prefix, major, named=True):
        disk = self.sys / "devices/block" / name
        disk.mkdir(parents=True)
        (disk / "dev").write_text(f"{major}:0\n")
        for number, label in enumerate(PI_PARTITIONS, start=1):
            partition = disk / f"{name}{prefix}{number}"
            partition.mkdir()
            (partition / "partition").write_text(f"{number}\n")
            partname = f"PARTNAME={label}\n" if named else ""
            (partition / "uevent").write_text(f"DEVNAME={partition.name}\n{partname}")
            (self.sys / "dev/block" / f"{major}:{number}").symlink_to(partition)

    def ask(self, root_device, *args):
        env = dict(os.environ, ROOT_DISK_PART_SYSFS=str(self.sys), TEST_ROOT_DEVICE=root_device,
                   PATH=f"{self.root / 'bin'}{os.pathsep}{os.environ['PATH']}")
        return subprocess.run(["sh", str(HELPER), *args], env=env, text=True,
                              capture_output=True, check=False)

    def boot_lines(self, fstab):
        fields = [line.split() for line in (FSTABS / fstab).read_text().splitlines()
                  if line.strip() and not line.lstrip().startswith("#")]
        return [entry for entry in fields if entry[1] == "/boot"]

    def test_sd_root_ignores_the_nvme_boot_partition(self):
        self.disk("mmcblk0", "p", 179)
        self.disk("nvme0n1", "p", 259)
        self.assertEqual(self.ask("179:3", "boot").stdout, "/dev/mmcblk0p1\n")
        self.assertEqual(self.ask("179:3", "boot", "mmcblk0p1").returncode, 0)
        self.assertEqual(self.ask("179:3", "boot", "nvme0n1p1").returncode, 1)

    def test_nvme_root_ignores_the_sd_boot_partition(self):
        self.disk("mmcblk0", "p", 179)
        self.disk("nvme0n1", "p", 259)
        self.assertEqual(self.ask("259:4", "boot").stdout, "/dev/nvme0n1p1\n")
        self.assertEqual(self.ask("259:4", "boot", "nvme0n1p1").returncode, 0)
        self.assertEqual(self.ask("259:4", "boot", "mmcblk0p1").returncode, 1)

    def test_usb_root_ignores_the_sd_boot_partition(self):
        self.disk("mmcblk0", "p", 179)
        self.disk("sda", "", 8)
        self.assertEqual(self.ask("8:3", "boot").stdout, "/dev/sda1\n")
        self.assertEqual(self.ask("8:3", "boot", "mmcblk0p1").returncode, 1)

    def test_mbr_root_disk_gets_no_link(self):
        self.disk("mmcblk0", "p", 179, named=False)
        self.assertEqual(self.ask("179:2", "boot", "mmcblk0p1").returncode, 1)

    def test_rule_links_only_what_the_helper_accepts(self):
        rule = " ".join(line.rstrip("\\").strip() for line in RULE.read_text().splitlines()
                        if not line.startswith("#"))
        self.assertEqual([key.strip() for key in rule.split(",")], [
            'ACTION!="remove"', 'SUBSYSTEM=="block"', 'ENV{ID_PART_ENTRY_SCHEME}=="gpt"',
            'ENV{ID_PART_ENTRY_NAME}=="boot"', 'PROGRAM="/usr/sbin/root-disk-part boot %k"',
            'SYMLINK+="wendyos/boot"'])

    @unittest.skipUnless(udevadm_can_verify(), "udevadm verify is not available")
    def test_rule_passes_udevadm_verify(self):
        result = subprocess.run(["udevadm", "verify", "--resolve-names=never", "--no-summary",
                                 str(RULE)], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_gpt_pi_fstab_mounts_boot_through_the_link(self):
        self.assertEqual(self.boot_lines("rpi-wendy-fstab"),
                         [["/dev/wendyos/boot", "/boot", "vfat", "defaults,nofail", "0", "2"]])

    def test_mbr_pi_fstab_keeps_the_label(self):
        self.assertEqual(self.boot_lines("rpi-wendy-mbr-fstab"),
                         [["LABEL=boot", "/boot", "vfat", "defaults", "0", "2"]])


if __name__ == "__main__":
    unittest.main()
