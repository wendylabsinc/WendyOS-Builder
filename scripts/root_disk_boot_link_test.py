"""Check the /dev/wendyos/boot link: the rule, the root-disk answer behind it, the fstabs,
and the image check that no fstab link ships without its rule."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "recipes-support/data-device/files"
HELPER = FILES / "root-disk-part"
RULE = FILES / "99-wendyos-boot.rules"
FSTABS = ROOT / "recipes-core/base-files/files"
LINKS_CLASS = ROOT / "classes/wendyos-links-check.bbclass"
# Every image recipe snippet whose fstab mounts /dev/wendyos links.
LINK_IMAGES = (ROOT / "meta-rpi-extensions/recipes-core/images/wendyos-image.bbappend",
               ROOT / "conf/distro/include/rockchip-image.inc")
PI_RULES = ("99-wendyos-boot.rules", "99-wendyos-config.rules", "99-wendyos-data.rules")
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


class FstabLinkCheckTests(unittest.TestCase):
    """Run check_wendyos_links against fake rootfs trees."""

    def run_check(self, fstab, rules, rules_dir="etc/udev/rules.d"):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        rootfs = Path(tmp.name)
        (rootfs / "etc").mkdir()
        (rootfs / "etc/fstab").write_text(fstab)
        if rules is not None:
            (rootfs / rules_dir).mkdir(parents=True)
            for name, text in rules.items():
                (rootfs / rules_dir / name).write_text(text)
        body = re.search(r"^check_wendyos_links\(\) \{\n(.*?)^\}", LINKS_CLASS.read_text(),
                         re.S | re.M).group(1)
        values = {"IMAGE_ROOTFS": rootfs, "sysconfdir": "/etc", "nonarch_base_libdir": "/usr/lib"}
        script = re.sub(r"\$\{(\w+)\}", lambda m: str(values[m.group(1)]), body)
        # bitbake runs shell tasks with -e and provides bbfatal.
        return subprocess.run(["sh", "-ec", 'bbfatal() { echo "$*" >&2; exit 1; }\n' + script],
                              text=True, capture_output=True, check=False)

    def shipped(self, *names):
        return {name: (FILES / name).read_text() for name in names}

    def test_shipped_pi_fstab_and_rules_pass(self):
        result = self.run_check((FSTABS / "rpi-wendy-fstab").read_text(), self.shipped(*PI_RULES))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_boot_rule_fails_the_build(self):
        result = self.run_check((FSTABS / "rpi-wendy-fstab").read_text(),
                                self.shipped("99-wendyos-config.rules", "99-wendyos-data.rules"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("/dev/wendyos/boot", result.stderr)
        # The message names what was searched for, so a rule written another way is found fast.
        self.assertIn('SYMLINK+="wendyos/boot"', result.stderr)

    def test_image_build_runs_the_check(self):
        lines = [line.strip() for line in LINKS_CLASS.read_text().splitlines()
                 if not line.lstrip().startswith("#")]
        self.assertIn('ROOTFS_POSTPROCESS_COMMAND += "check_wendyos_links"', lines)
        for image in LINK_IMAGES:
            with self.subTest(image=image.relative_to(ROOT)):
                lines = [line.strip() for line in image.read_text().splitlines()
                         if not line.lstrip().startswith("#")]
                self.assertIn("inherit wendyos-links-check", lines)

    def test_pi3_fstab_needs_only_the_data_rule(self):
        result = self.run_check((FSTABS / "rpi-wendy-mbr-fstab").read_text(),
                                self.shipped("99-wendyos-data.rules"))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rule_under_usr_lib_counts(self):
        result = self.run_check("/dev/wendyos/boot /boot vfat defaults,nofail 0 2\n",
                                self.shipped("99-wendyos-boot.rules"), "usr/lib/udev/rules.d")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_commented_out_rule_does_not_count(self):
        rule = "".join("# " + line for line in (FILES / "99-wendyos-boot.rules").read_text()
                       .splitlines(keepends=True))
        result = self.run_check("/dev/wendyos/boot /boot vfat defaults,nofail 0 2\n",
                                {"99-wendyos-boot.rules": rule})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("/dev/wendyos/boot", result.stderr)

    def test_commented_out_fstab_line_needs_no_rule(self):
        result = self.run_check("# /dev/wendyos/boot /boot vfat defaults,nofail 0 2\n", None)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_no_rules_directory_fails_with_a_message(self):
        result = self.run_check("/dev/wendyos/boot /boot vfat defaults,nofail 0 2\n", None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("/dev/wendyos/boot", result.stderr)


if __name__ == "__main__":
    unittest.main()
