"""Run the shipped Orin initramfs root lookup under busybox against fake efivars and sysfs."""

import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RECIPE_DIR = ROOT / "meta-tegra-extensions/recipes-core/initrdscripts"
FILES = RECIPE_DIR / "tegra-minimal-init"
HELPER = FILES / "wendyos-find-root.sh"
PREBOOT = FILES / "wendyos-platform-preboot.sh"
INIT = FILES / "wendyos-init-boot.sh"
BBAPPEND = RECIPE_DIR / "tegra-minimal-init_%.bbappend"

# meta-tegra's init-boot.sh and platform-preboot.sh that the WendyOS copies are merged from.
UPSTREAM_INIT_SHA256 = "7a719a98f45bd0d526df2e2f07e884a5af51050fb7aa965dc3b6a1975cee09a8"
UPSTREAM_PREBOOT_SHA256 = "4423a2f418d8f9d529b2650a85bf59e8edb2a8aed564e2bd1c908417b49e1875"

GLOBAL = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
NVIDIA = "781e084c-a330-417c-b678-38e696380cb9"

# Commands of the shipped tegra-minimal-initramfs: the scripts may use nothing else.
INITRD_APPLETS = set("""
[ [[ addgroup adduser ascii ash awk base32 basename blkid blkid.util-linux bunzip2 busybox
busybox.nosuid busybox.suid bzcat bzip2 cat chattr chgrp chmod chown chroot chvt cksum clear cmp
cp cpio crc32 cut date dc dd deallocvt delgroup deluser depmod depmod.kmod df diff dirname dmesg
dnsdomainname du dumpkmap dumpleases echo egrep env expr false fbset fdisk fgrep find flock free
fsck fstrim fuser getfattr getopt getty grep groups gunzip gzip head hexdump hostname hwclock id
ifdown ifup insmod insmod.kmod ip kill killall kmod ldconfig less ln loadfont loadkmap logger
login logname logread losetup ls lsmod lsmod.kmod lspci lsusb lzcat md5sum mdev mesg microcom
mkdir mkdosfs mkfifo mkfs.vfat mknod mkswap mktemp modinfo modinfo.kmod modprobe modprobe.kmod
more mount mountpoint mv nc nohup nproc nsenter nslookup od openvt passwd patch pgrep pidof ping
ping6 pivot_root printf ps pwd rdate readlink realpath reboot renice reset resize rev rfkill rm
rmdir rmmod rmmod.kmod run-parts sed seq setconsole setsid sh sha1sum sha256sum shuf sleep sort
start-stop-daemon stat strings stty su sulogin swapoff swapon switch_root sync sysctl tail tar
tee telnet test tftp time top touch tr traceroute true ts tty udhcpc udhcpd umount uname uniq
unlink unzip uptime users usleep uuidgen vi vlock watch wc wget which who whoami xargs xzcat yes
zcat
""".split())
STUBS = {"blkid", "modprobe", "mount", "reboot", "sh", "sleep", "switch_root", "umount"}
PREBOOT_PASSES = 240
# Stops a runaway loop in the scripts under test.
SLEEP_LIMIT = 300

BUSYBOX = shutil.which("busybox")


def host_block_device():
    for entry in sorted(os.listdir("/dev")):
        try:
            if stat.S_ISBLK(os.stat("/dev/" + entry).st_mode):
                return "/dev/" + entry
        except OSError:
            continue
    return None


BLOCK_DEVICE = host_block_device()
MISSING = ("needs busybox: the initramfs runs these scripts under its ash" if not BUSYBOX else
           "needs a host block device to stand in for /dev nodes" if not BLOCK_DEVICE else None)


def dump(text):
    return bytes.fromhex(text)


# Efivars as dumped (hexdump -C) on real boards, attribute bytes and OptionalData included.
NANO_BOOT0001 = dump("""
07 00 00 00 01 00 00 00 58 00 55 00 45 00 46 00  49 00 20 00 53 00 61 00 6d 00 73 00 75 00 6e 00
67 00 20 00 53 00 53 00 44 00 20 00 39 00 39 00  30 00 20 00 50 00 52 00 4f 00 20 00 31 00 54 00
42 00 20 00 53 00 37 00 48 00 44 00 4e 00 53 00  30 00 4c 00 32 00 30 00 30 00 39 00 33 00 31 00
56 00 20 00 31 00 00 00 01 04 14 00 2c 43 5a 1e  66 04 31 4d b0 09 d4 d9 23 92 71 d3 01 03 18 00
0b 00 00 00 00 00 16 14 00 00 00 00 ff ff 17 14  00 00 00 00 02 01 0c 00 d0 41 03 0a 00 00 00 00
01 01 06 00 00 00 01 01 06 00 00 00 03 17 10 00  01 00 00 00 00 25 38 42 61 40 e8 0f 7f ff 04 00
4e ac 08 81 11 9f 59 4d 85 0e e2 1a 52 2c 59 b2
""")
AGX_BOOT0001 = dump("""
07 00 00 00 01 00 00 00 3d 00 55 00 45 00 46 00  49 00 20 00 53 00 61 00 6e 00 44 00 69 00 73 00
6b 00 20 00 44 00 47 00 34 00 30 00 36 00 34 00  20 00 30 00 32 00 31 00 35 00 46 00 30 00 39 00
30 00 20 00 65 00 4d 00 4d 00 43 00 20 00 55 00  73 00 65 00 72 00 20 00 44 00 61 00 74 00 61 00
00 00 01 04 14 00 2c 43 5a 1e 66 04 31 4d b0 09  d4 d9 23 92 71 d3 01 03 18 00 0b 00 00 00 00 00
46 03 00 00 00 00 ff ff 47 03 00 00 00 00 03 1d  05 00 00 01 05 08 00 00 00 00 00 7f ff 04 00 4e
ac 08 81 11 9f 59 4d 85 0e e2 1a 52 2c 59 b2
""")
THOR_BOOT0001 = dump("""
07 00 00 00 01 00 00 00 58 00 55 00 45 00 46 00  49 00 20 00 57 00 44 00 20 00 50 00 43 00 20 00
53 00 4e 00 35 00 30 00 30 00 30 00 53 00 20 00  53 00 44 00 45 00 50 00 4e 00 53 00 4a 00 2d 00
31 00 54 00 30 00 30 00 20 00 32 00 35 00 32 00  33 00 32 00 31 00 38 00 30 00 35 00 37 00 31 00
33 00 20 00 31 00 00 00 01 04 14 00 2c 43 5a 1e  66 04 31 4d b0 09 d4 d9 23 92 71 d3 01 03 18 00
0b 00 00 00 00 00 48 08 a8 00 00 00 ff 3f 48 08  a8 00 00 00 02 01 0c 00 d0 41 03 0a 05 00 00 00
01 01 06 00 00 00 01 01 06 00 00 00 03 17 10 00  01 00 00 00 00 1b 44 8b 42 8b e3 ed 7f ff 04 00
4e ac 08 81 11 9f 59 4d 85 0e e2 1a 52 2c 59 b2
""")
# "Enter Setup": a firmware application, not a disk.
NANO_BOOT0000 = dump("""
07 00 00 00 09 01 00 00 2c 00 45 00 6e 00 74 00  65 00 72 00 20 00 53 00 65 00 74 00 75 00 70 00
00 00 04 07 14 00 15 9a a7 49 69 8f e7 4b a3 0c  a1 72 f4 4a bc e7 04 06 14 00 21 aa 2c 46 14 76
03 45 83 6e 8a b6 f4 66 23 31 7f ff 04 00
""")
BOOT_CURRENT_0001 = dump("06 00 00 00 01 00")
SLOT_A = dump("06 00 00 00 00 00 00 00")
SLOT_B = dump("06 00 00 00 01 00 00 00")
REDUNDANCY_ON = dump("06 00 00 00 01 00 00 00")
REDUNDANCY_OFF = dump("06 00 00 00 00 00 00 00")

NANO_NVME = "devices/platform/bus@0/14160000.pcie/pci0004:00/0004:00:00.0/0004:01:00.0/nvme/nvme0/nvme0n1"
NANO_EUI = "00 25 38 42 61 40 e8 0f"
AGX_EMMC = "devices/platform/bus@0/3460000.mmc/mmc_host/mmc0/mmc0:0001/block/mmcblk0"
THOR_NVME = "devices/platform/bus@0/a808480000.pcie/pci0005:00/0005:00:00.0/0005:01:00.0/nvme/nvme0/nvme0n1"
SD_CARD = "devices/platform/bus@0/3400000.mmc/mmc_host/mmc1/mmc1:aaaa/block/mmcblk1"

WENDYOS_ORIN = dict(enumerate([
    "APP", "APP_b", "A_kernel", "A_kernel-dtb", "A_reserved_on_user", "B_kernel", "B_kernel-dtb",
    "B_reserved_on_user", "recovery", "recovery-dtb", "esp", "recovery_alt", "recovery-dtb_alt",
    "esp_alt", "UDA", "config", "data"], start=1))
WENDYOS_THOR = {1: "APP", 2: "APP_b", 3: "recovery", 4: "recovery-dtb", 5: "esp",
                6: "A_reserved_on_user", 7: "recovery_alt", 8: "recovery-dtb_alt", 9: "esp_alt",
                10: "B_reserved_on_user", 11: "UDA", 16: "config", 17: "data"}
# A factory JetPack disk: no config or data partition.
JETPACK = dict(enumerate([
    "APP", "A_kernel", "A_kernel-dtb", "A_reserved_on_user", "B_kernel", "B_kernel-dtb",
    "B_reserved_on_user", "recovery", "recovery-dtb", "esp", "recovery_alt", "recovery-dtb_alt",
    "esp_alt", "UDA"], start=1))


def node(kind, subtype, data=b""):
    return bytes([kind, subtype]) + (4 + len(data)).to_bytes(2, "little") + data


def memory_mapped(start):
    return node(1, 3, (11).to_bytes(4, "little") + start.to_bytes(8, "little")
                + (start + 0x1ffff).to_bytes(8, "little"))


def nvme_node(nsid=1, eui=NANO_EUI):
    return node(3, 0x17, nsid.to_bytes(4, "little") + bytes.fromhex(eui))


VENDOR = dump("01 04 14 00 2c 43 5a 1e 66 04 31 4d b0 09 d4 d9 23 92 71 d3")
PCI_PATH = dump("02 01 0c 00 d0 41 03 0a 00 00 00 00 01 01 06 00 00 00 01 01 06 00 00 00")
SD_NODE = node(3, 0x1a, b"\0")
USB_NODE = node(3, 0x05, b"\1\0")
MAC_NODE = node(3, 0x0b, bytes(33))
HD_NODE = node(4, 1, bytes(38))
FILE_NODE = node(4, 4, "\\EFI\\BOOT\\BOOTAA64.EFI\0".encode("utf-16-le"))
END = node(0x7f, 0xff)


def load_option(*nodes, description="Test", data=b""):
    path = b"".join(nodes)
    return (dump("07 00 00 00 01 00 00 00") + len(path).to_bytes(2, "little")
            + (description + "\0").encode("utf-16-le") + path + data)


# CI must run these, never skip them.
@unittest.skipIf(MISSING and not os.environ.get("CI"), MISSING)
class InitramfsCase(unittest.TestCase):
    def setUp(self):
        if MISSING:
            self.fail(MISSING)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.efivars = self.root / "sys/firmware/efi/efivars"
        self.efivars.mkdir(parents=True)
        (self.root / "sys/block").mkdir()
        self.dev = self.root / "dev"
        self.dev.mkdir()
        (self.root / "proc").mkdir()
        (self.root / "hooks").mkdir()
        self.cmdline("")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.available = set(subprocess.run([BUSYBOX, "--list"], capture_output=True,
                                            text=True, check=True).stdout.split())
        for applet in (INITRD_APPLETS & self.available) - STUBS:
            (self.bin / applet).symlink_to(BUSYBOX)
        self.env = {"PATH": str(self.bin)}
        self.stubs()
        self.helper = self.install(HELPER, "find-root", prelude=self.helper_stubs,
                                   efivars=self.efivars, sysblock=self.root / "sys/block",
                                   devdir=self.dev)

    def install(self, source, name, prelude=None, **paths):
        """Copy a shipped script with its path-definition lines pointed into the fixture."""
        text = source.read_text().replace("#!/bin/sh\n", f"#!{BUSYBOX} sh\n", 1)
        if prelude is not None:
            shebang, rest = text.split("\n", 1)
            text = f"{shebang}\n. {prelude}\n{rest}"
        for variable, value in paths.items():
            text, count = re.subn(rf"^{variable}=.*$", f"{variable}={value}", text, flags=re.M)
            self.assertEqual(count, 1, f"{source.name} has no {variable}= line")
        target = self.root / name
        target.write_text(text)
        target.chmod(0o755)
        return target

    def replace(self, text, old, new):
        self.assertIn(old, text)
        return text.replace(old, new)

    def stubs(self):
        # Functions, because a distro busybox may run its own applets ahead of PATH.
        root = self.root
        missing = sorted(applet for applet in self.available - INITRD_APPLETS
                         if re.fullmatch(r"[A-Za-z_]\w*", applet))
        applets = root / "applets.sh"
        applets.write_text("".join(f'{name}() {{ echo "{name}: not found" >&2; return 127; }}\n'
                                   for name in missing))
        # The helper's settle sleep; hooks/settle runs once inside it.
        self.helper_stubs = root / "helper-stubs.sh"
        self.helper_stubs.write_text(
            f". {applets}\nsleep() {{\n    echo \"settle $*\" >> {root}/calls\n"
            f"    [ ! -f {root}/hooks/settle ] || . {root}/hooks/settle\n"
            f"    rm -f {root}/hooks/settle\n}}\n")
        functions = {
            # One sleep per preboot pass; hooks/<n> runs after the nth.
            "sleep": f"""stub_sleeps=$((stub_sleeps + 1))
    [ ! -f {root}/hooks/$stub_sleeps ] || . {root}/hooks/$stub_sleeps
    [ "$stub_sleeps" -lt {SLEEP_LIMIT} ] || exit 99""",
            "mount": f"""case "$*" in *" {root}/mnt") ;; *) return 0 ;; esac
    case "$(cat {root}/mount-mode)" in
        ok) mkdir -p {root}/mnt/sbin && ln -s /nonexistent/systemd {root}/mnt/sbin/init ;;
        no-init) mkdir -p {root}/mnt ;;
        *) return 32 ;;
    esac""",
            "blkid": f"[ ! -f {root}/blkid-out ] || cat {root}/blkid-out",
            "modprobe": ":", "reboot": ":", "umount": ":",
        }
        self.stub_file = root / "stubs.sh"
        self.stub_file.write_text(f". {applets}\nstub_sleeps=0\n" + "".join(
            f'{name}() {{\n    echo "{name} $*" >> {root}/calls\n    {body}\n}}\n'
            for name, body in functions.items()))
        for name in ("sh", "switch_root"):
            (self.bin / name).write_text(f'#!{BUSYBOX} sh\necho "{name} $*" >> {root}/calls\n')
            (self.bin / name).chmod(0o755)

    def calls(self):
        path = self.root / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def sleeps(self):
        return sum(1 for call in self.calls() if call.startswith("sleep "))

    def after_sleep(self, count, commands):
        (self.root / "hooks" / str(count)).write_text(commands + "\n")

    def cmdline(self, text):
        (self.root / "proc/cmdline").write_text(text + "\n")

    def efivar(self, name, guid, data):
        (self.efivars / f"{name}-{guid}").write_bytes(data)

    def boot(self, option, number=1, slot=SLOT_B):
        self.efivar("BootCurrent", GLOBAL, BOOT_CURRENT_0001[:4] + number.to_bytes(2, "little"))
        if option is not None:
            self.efivar(f"Boot{number:04X}", GLOBAL, option)
        self.efivar("BootChainOsCurrent", NVIDIA, slot)

    def disk(self, name, devpath, partitions, nsid=None, eui=None, card=None, nodes=True,
             link=True):
        directory = self.root / "sys" / devpath
        directory.mkdir(parents=True)
        for attribute, value in (("nsid", nsid), ("eui", eui), ("device/type", card)):
            if value is not None:
                (directory / attribute).parent.mkdir(exist_ok=True)
                (directory / attribute).write_text(value + "\n")
        for number, label in partitions.items():
            partition = self.partition(directory, name, number, label)
            if nodes:
                self.node(partition)
        if link:
            (self.root / "sys/block" / name).symlink_to("../" + devpath)

    def partition(self, directory, disk, number, label):
        partition = f"{disk}{'p' if disk[-1].isdigit() else ''}{number}"
        (directory / partition).mkdir(parents=True)
        (directory / partition / "partition").write_text(f"{number}\n")
        (directory / partition / "uevent").write_text(
            f"MAJOR=259\nMINOR={number}\nDEVNAME={partition}\nDEVTYPE=partition\n"
            f"PARTN={number}\nPARTNAME={label}\n")
        return partition

    def late_partition(self, devpath, disk, number, label):
        """Shell commands that add a partition and its node, as the kernel would later."""
        staged = self.root / "staged"
        partition = self.partition(staged, disk, number, label)
        return (f"mv {staged}/{partition} {self.root}/sys/{devpath}/\n"
                f"ln -s {BLOCK_DEVICE} {self.dev}/{partition}")

    def during_settle(self, commands):
        (self.root / "hooks/settle").write_text(commands + "\n")

    def node(self, name):
        # Unprivileged tests cannot mknod; a symlink to a real block device passes [ -b ].
        (self.dev / name).symlink_to(BLOCK_DEVICE)

    def nano(self, **kwargs):
        self.disk("nvme0n1", NANO_NVME, WENDYOS_ORIN, nsid="1", eui=NANO_EUI, **kwargs)

    def agx_emmc(self, partitions=WENDYOS_ORIN):
        self.disk("mmcblk0", AGX_EMMC, partitions, card="MMC")
        for boot in ("mmcblk0boot0", "mmcblk0boot1"):
            self.disk(boot, f"{AGX_EMMC}/{boot}", {}, card="MMC")

    def find_root(self, slot="_b", bootdrive="", fallbacks="none"):
        result = subprocess.run([BUSYBOX, "sh", str(self.helper), slot, bootdrive, fallbacks],
                                env=self.env, capture_output=True, text=True, timeout=60,
                                check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 1, result.stdout + result.stderr)
        return result.stdout.strip()

    def assert_root(self, partition, source, **kwargs):
        self.assertEqual(self.find_root(**kwargs), f"root {self.dev}/{partition} {source}")

    def assert_wait(self, reason="", **kwargs):
        answer = self.find_root(**kwargs)
        self.assertTrue(answer.startswith("wait "), answer)
        self.assertIn(reason, answer)

    def clear_efivars(self):
        for entry in self.efivars.iterdir():
            entry.unlink()


class FindRootTests(InitramfsCase):
    def test_nano_nvme_follows_the_firmware_slot(self):
        self.boot(NANO_BOOT0001)
        self.nano()
        self.assert_root("nvme0n1p1", "bootcurrent", slot="")
        self.assert_root("nvme0n1p2", "bootcurrent", slot="_b")

    def test_agx_emmc_ignores_boot_partitions(self):
        self.boot(AGX_BOOT0001)
        self.agx_emmc()
        self.assert_root("mmcblk0p2", "bootcurrent")

    def test_thor_nvme_on_a_64_bit_controller_address(self):
        self.boot(THOR_BOOT0001)
        self.disk("nvme0n1", THOR_NVME, WENDYOS_THOR, nsid="1", eui="00 1b 44 8b 42 8b e3 ed")
        self.assert_root("nvme0n1p1", "bootcurrent", slot="")

    def test_nano_sd_card(self):
        self.boot(load_option(VENDOR, memory_mapped(0x3400000), SD_NODE, END))
        self.disk("mmcblk1", SD_CARD, WENDYOS_ORIN, card="SD")
        self.assert_root("mmcblk1p2", "bootcurrent")

    def test_sd_option_does_not_match_an_emmc_on_its_controller(self):
        self.boot(load_option(VENDOR, memory_mapped(0x3400000), SD_NODE, END))
        self.disk("mmcblk1", SD_CARD, WENDYOS_ORIN, card="MMC")
        self.assert_wait("boot disk not found")

    def test_agx_emmc_boot_wins_over_wendyos_on_nvme_and_bootdrive(self):
        self.boot(AGX_BOOT0001)
        self.agx_emmc()
        self.nano()
        self.assert_root("mmcblk0p2", "bootcurrent", bootdrive="/dev/nvme0n1",
                         fallbacks="bootdrive")

    def test_agx_nvme_boot_ignores_jetpack_emmc(self):
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), PCI_PATH, nvme_node(), END))
        self.agx_emmc(JETPACK)
        self.nano()
        self.assert_root("nvme0n1p2", "bootcurrent", bootdrive="/dev/mmcblk0",
                         fallbacks="bootdrive")

    def test_media_node_wins_over_later_partition_and_file_nodes(self):
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), PCI_PATH, nvme_node(),
                              HD_NODE, FILE_NODE, END))
        self.nano()
        self.assert_root("nvme0n1p2", "bootcurrent")

    def test_zero_eui_matches_on_namespace_and_controller(self):
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), nvme_node(eui="00" * 8), END))
        self.nano()
        self.assert_root("nvme0n1p2", "bootcurrent")

    def test_controller_is_the_memory_mapped_address_as_a_whole_path_component(self):
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), nvme_node(eui="00" * 8), END))
        self.disk("nvme0n1", NANO_NVME.replace("14160000", "141a0000"), WENDYOS_ORIN, nsid="1")
        self.disk("nvme1n1", NANO_NVME.replace("nvme0/nvme0n1", "nvme1/nvme1n1"), WENDYOS_ORIN,
                  nsid="1")
        self.assert_root("nvme1n1p2", "bootcurrent")
        self.boot(load_option(VENDOR, memory_mapped(0x4160000), nvme_node(eui="00" * 8), END))
        self.assert_wait("boot disk not found")

    def test_eui_mismatch_is_another_disk(self):
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), nvme_node(eui="11" * 8), END))
        self.nano()
        self.assert_wait("boot disk not found")
        # A decided disk is never replaced by the only WendyOS disk.
        self.assert_wait("boot disk not found", fallbacks="any")

    def test_decided_disk_without_partitions_is_not_replaced(self):
        self.boot(NANO_BOOT0001)
        self.disk("nvme0n1", NANO_NVME, {}, nsid="1", eui=NANO_EUI)
        self.agx_emmc()
        self.assertEqual(self.find_root(fallbacks="any"), "wait no usable APP_b on nvme0n1")

    def test_decided_disk_without_nodes_is_not_replaced(self):
        self.boot(NANO_BOOT0001)
        self.nano(nodes=False)
        self.agx_emmc()
        self.assertEqual(self.find_root(fallbacks="any"), "wait no usable APP_b on nvme0n1")

    def test_namespace_mismatch_is_another_disk(self):
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), nvme_node(nsid=2), END))
        self.nano()
        self.assert_wait("boot disk not found")

    def test_missing_sysfs_eui_matches_on_namespace_and_controller(self):
        self.boot(NANO_BOOT0001)
        self.disk("nvme0n1", NANO_NVME, WENDYOS_ORIN, nsid="1")
        self.assert_root("nvme0n1p2", "bootcurrent")

    def test_two_namespaces_matching_one_option_are_ambiguous(self):
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), nvme_node(eui="00" * 8), END))
        self.nano()
        self.disk("nvme1n1", NANO_NVME.replace("nvme0/nvme0n1", "nvme1/nvme1n1"), WENDYOS_ORIN,
                  nsid="1")
        self.assert_wait("2 disks match")
        self.assert_root("nvme0n1p2", "bootdrive", bootdrive="/dev/nvme0n1", fallbacks="bootdrive")

    def test_multipath_head_is_not_matched(self):
        # Only NVMe multipath makes nvme0c0n1, and it then moves nvme0n1 off the controller.
        self.boot(NANO_BOOT0001)
        self.disk("nvme0n1", "devices/virtual/nvme-subsystem/nvme-subsys0/nvme0n1",
                  WENDYOS_ORIN, nsid="1", eui=NANO_EUI)
        self.disk("nvme0c0n1", NANO_NVME.replace("nvme0n1", "nvme0c0n1"), {}, nsid="1",
                  eui=NANO_EUI)
        self.assert_wait("boot disk not found")
        self.assert_root("nvme0n1p2", "bootdrive", bootdrive="/dev/nvme0n1", fallbacks="bootdrive")

    def test_boot_option_number_is_four_uppercase_hex_digits(self):
        self.nano()
        for number in (0x000A, 0x0100):
            with self.subTest(number=hex(number)):
                self.clear_efivars()
                self.boot(NANO_BOOT0001, number=number)
                self.assert_root("nvme0n1p2", "bootcurrent")

    def test_first_memory_mapped_node_names_the_controller(self):
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), memory_mapped(0x3400000),
                              nvme_node(), END))
        self.nano()
        self.assert_root("nvme0n1p2", "bootcurrent")

    def test_undecided_boot_options_wait_without_fallback(self):
        malformed, not_a_disk = "Boot0001 is malformed", "Boot0001 is not an NVMe, eMMC or SD disk"
        short_list = bytearray(NANO_BOOT0001)
        short_list[8:10] = (0x30).to_bytes(2, "little")
        cases = {
            "no BootCurrent": (None, "no BootCurrent"),
            "no Boot0001": (b"", "no Boot0001"),
            "firmware application": (NANO_BOOT0000, not_a_disk),
            "network": (load_option(VENDOR, memory_mapped(0x140a0000), PCI_PATH, MAC_NODE, END),
                        not_a_disk),
            "usb": (load_option(VENDOR, memory_mapped(0x3610000), USB_NODE, HD_NODE, END),
                    not_a_disk),
            "partition only": (load_option(HD_NODE, FILE_NODE, END), not_a_disk),
            "12-byte NVMe node": (load_option(VENDOR, memory_mapped(0x14160000),
                                              node(3, 0x17, bytes(8)), END), not_a_disk),
            "no controller": (load_option(VENDOR, PCI_PATH, nvme_node(), END),
                              "Boot0001 names no controller"),
            "controller after the disk": (load_option(VENDOR, nvme_node(),
                                                      memory_mapped(0x14160000), END),
                                          "Boot0001 names no controller"),
            "disk in a second instance": (load_option(HD_NODE, FILE_NODE, node(0x7f, 0x01), VENDOR,
                                                      memory_mapped(0x14160000), nvme_node(), END),
                                          not_a_disk),
            "empty option": (b"", malformed),
            "attributes only": (dump("07 00 00 00"), malformed),
            "short node": (load_option(VENDOR, memory_mapped(0x14160000), dump("03 17 02 00"),
                                       END), malformed),
            "zero-length node": (load_option(VENDOR, memory_mapped(0x14160000),
                                             dump("03 17 00 00"), END), malformed),
            "node past the path": (load_option(VENDOR, memory_mapped(0x14160000), END)[:-4]
                                   + dump("03 17 40 00 7f ff 04 00"), malformed),
            "path list shorter than the path": (bytes(short_list), malformed),
            "path past the file": (NANO_BOOT0001[:-24], malformed),
            "no end node": (load_option(VENDOR, memory_mapped(0x14160000), nvme_node()), malformed),
            "unterminated description": (dump("07 00 00 00 01 00 00 00 30 00 41 00 42"), malformed),
            "odd description": (NANO_BOOT0001[:12] + b"\x41" + NANO_BOOT0001[12:], malformed),
        }
        for case, (option, reason) in cases.items():
            with self.subTest(case=case):
                self.clear_efivars()
                if case == "no BootCurrent":
                    self.efivar("BootChainOsCurrent", NVIDIA, SLOT_B)
                elif case == "no Boot0001":
                    self.boot(None)
                else:
                    self.boot(option)
                if not (self.root / "sys/block/nvme0n1").exists():
                    self.nano()
                self.assertEqual(self.find_root(), f"wait {reason}")
                # Today's lookup on the build-time disk still applies.
                self.assert_root("nvme0n1p2", "bootdrive", bootdrive="/dev/nvme0n1",
                                 fallbacks="bootdrive")

    def test_bootdrive_is_only_a_fallback_when_asked(self):
        self.boot(NANO_BOOT0000)
        self.nano()
        self.assert_wait()
        self.assert_root("nvme0n1p2", "bootdrive", bootdrive="/dev/nvme0n1", fallbacks="bootdrive")

    def test_absent_boot_disk_falls_back_to_bootdrive(self):
        self.boot(NANO_BOOT0001)
        self.agx_emmc()
        self.assert_wait("boot disk not found", bootdrive="/dev/mmcblk0")
        self.assert_root("mmcblk0p2", "bootdrive", bootdrive="/dev/mmcblk0", fallbacks="bootdrive")

    def test_bootdrive_does_not_beat_a_decided_boot_disk_early(self):
        # Firmware booted the NVMe; only the eMMC the image was built for is up so far.
        self.boot(NANO_BOOT0001)
        self.agx_emmc()
        self.assertEqual(self.find_root(bootdrive="/dev/mmcblk0", fallbacks="undecided"),
                         "wait boot disk not found")
        self.disk("nvme0n1", NANO_NVME, {}, nsid="1", eui=NANO_EUI)
        self.assertEqual(self.find_root(bootdrive="/dev/mmcblk0", fallbacks="undecided"),
                         "wait no usable APP_b on nvme0n1")
        self.assert_root("mmcblk0p2", "bootdrive", bootdrive="/dev/mmcblk0", fallbacks="bootdrive")

    def test_undecided_option_uses_bootdrive_on_every_pass(self):
        self.boot(NANO_BOOT0000)
        self.nano()
        self.assert_root("nvme0n1p2", "bootdrive", bootdrive="/dev/nvme0n1", fallbacks="undecided")

    def test_late_single_disk_covers_a_boot_disk_decoded_wrongly(self):
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), nvme_node(eui="11" * 8), END))
        self.nano()
        self.agx_emmc()
        self.assertEqual(self.find_root(fallbacks="any"), "wait boot disk not found")
        # The eMMC is another medium: it neither stands in nor counts as a second WendyOS disk.
        self.assert_root("nvme0n1p2", "single-disk", fallbacks="late")
        # A build-time disk keeps today's lookup instead.
        self.assert_wait("boot disk not found", bootdrive="/dev/mmcblk1", fallbacks="late")

    def test_late_single_disk_is_only_of_the_media_uefi_booted(self):
        # Options whose controller or EUI no disk has, as when Linux never finds the boot disk.
        options = {"nvme": load_option(VENDOR, memory_mapped(0x14160000), nvme_node(eui="11" * 8), END),
                   "mmc": load_option(VENDOR, memory_mapped(0x3410000), node(3, 0x1d, b"\0"), END),
                   "sd": load_option(VENDOR, memory_mapped(0x3410000), SD_NODE, END)}
        disks = {"nvme": ("nvme0n1", NANO_NVME), "mmc": ("mmcblk0", AGX_EMMC),
                 "sd": ("mmcblk1", SD_CARD)}
        self.nano(link=False)
        self.disk("mmcblk0", AGX_EMMC, WENDYOS_ORIN, card="MMC", link=False)
        self.disk("mmcblk1", SD_CARD, WENDYOS_ORIN, card="SD", link=False)
        for booted, option in options.items():
            self.boot(option)
            for media, (name, devpath) in disks.items():
                with self.subTest(booted=booted, disk=media):
                    link = self.root / "sys/block" / name
                    link.symlink_to("../" + devpath)
                    try:
                        if media == booted:
                            self.assert_root(f"{name}p2", "single-disk", fallbacks="late")
                        else:
                            self.assertEqual(self.find_root(fallbacks="late"), "wait boot disk not found")
                    finally:
                        link.unlink()

    def test_late_nvme_stand_in_is_behind_the_boot_controller(self):
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), nvme_node(eui="11" * 8), END))
        # A second NVMe on another controller is not the disk UEFI booted.
        self.disk("nvme1n1", NANO_NVME.replace("14160000", "141a0000").replace("nvme0", "nvme1"),
                  WENDYOS_ORIN, nsid="1", eui="22" * 8)
        self.assertEqual(self.find_root(fallbacks="late"), "wait boot disk not found")
        # One behind the boot controller stands in, and the other is not a second WendyOS disk.
        self.nano()
        self.assert_root("nvme0n1p2", "single-disk", fallbacks="late")

    def ambiguous_nvme(self, partitions=None):
        """Two namespace-1 NVMe disks behind the boot controller, an option with no EUI to tell them apart."""
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), nvme_node(eui="00" * 8), END))
        self.disk("nvme0n1", NANO_NVME, partitions or JETPACK, nsid="1")
        self.disk("nvme1n1", NANO_NVME.replace("nvme0/nvme0n1", "nvme1/nvme1n1"), JETPACK, nsid="1")

    def test_ambiguous_boot_disk_takes_no_other_media(self):
        self.ambiguous_nvme()
        self.agx_emmc()
        self.disk("mmcblk1", SD_CARD, WENDYOS_ORIN, card="SD")
        for fallbacks in ("any", "late"):
            self.assertEqual(self.find_root(fallbacks=fallbacks), "wait 2 disks match the boot option",
                             fallbacks)

    def test_ambiguous_boot_disk_takes_its_one_wendyos_candidate(self):
        self.ambiguous_nvme(WENDYOS_ORIN)
        # WendyOS on another medium neither stands in nor counts as a second disk.
        self.agx_emmc()
        self.assertEqual(self.find_root(), "wait 2 disks match the boot option")
        self.assert_root("nvme0n1p2", "single-disk", fallbacks="any")
        self.assert_root("nvme0n1p2", "single-disk", fallbacks="late")

    def test_late_single_disk_never_replaces_a_boot_disk_linux_found(self):
        self.boot(NANO_BOOT0001)
        self.disk("nvme0n1", NANO_NVME, {}, nsid="1", eui=NANO_EUI)
        self.agx_emmc()
        self.assertEqual(self.find_root(fallbacks="late"), "wait no usable APP_b on nvme0n1")

    def test_single_wendyos_disk_needs_an_undecided_option_and_no_bootdrive(self):
        self.boot(NANO_BOOT0000)
        self.nano()
        self.agx_emmc(JETPACK)
        self.assert_wait()
        self.assert_root("nvme0n1p2", "single-disk", fallbacks="any")
        self.assert_wait("no usable APP_b on mmcblk1", bootdrive="/dev/mmcblk1", fallbacks="any")

    def test_two_wendyos_disks_wait(self):
        self.boot(NANO_BOOT0000)
        self.nano()
        self.agx_emmc()
        self.assert_wait("2 WendyOS disks", fallbacks="any")

    def test_single_disk_counts_only_whole_wendyos_disks(self):
        self.boot(NANO_BOOT0000)
        self.nano()
        usb = "devices/platform/bus@0/3610000.usb/usb1/1-1/1-1:1.0/host0/target0:0:0/block/sda"
        others = {
            "usb disk": ("sda", usb, WENDYOS_ORIN),
            "eMMC boot partition": ("mmcblk0boot0", f"{AGX_EMMC}/mmcblk0boot0", WENDYOS_ORIN),
            "no APP": ("mmcblk1", SD_CARD, {10: "esp", 16: "config", 17: "data"}),
            "no esp": ("mmcblk2", AGX_EMMC.replace("mmc0", "mmc2").replace("mmcblk0", "mmcblk2"),
                       {1: "APP", 2: "APP_b", 16: "config", 17: "data"}),
        }
        for case, (name, devpath, partitions) in others.items():
            with self.subTest(case=case):
                self.disk(name, devpath, partitions)
                self.assert_root("nvme0n1p2", "single-disk", fallbacks="any")
                (self.root / "sys/block" / name).unlink()

    def test_non_ab_disk_runs_slot_b_from_app(self):
        self.boot(NANO_BOOT0001)
        self.disk("nvme0n1", NANO_NVME, {1: "APP", 11: "esp", 16: "config", 17: "data"},
                  nsid="1", eui=NANO_EUI)
        self.assert_root("nvme0n1p1", "bootcurrent", slot="_b")
        self.assertEqual(self.calls(), ["settle 0.5"])
        self.assert_root("nvme0n1p1", "bootcurrent", slot="")

    def test_slot_b_never_takes_app_while_app_b_is_being_added(self):
        self.boot(NANO_BOOT0001)
        self.disk("nvme0n1", NANO_NVME, {1: "APP"}, nsid="1", eui=NANO_EUI)
        self.during_settle(self.late_partition(NANO_NVME, "nvme0n1", 2, "APP_b"))
        self.assert_root("nvme0n1p2", "bootcurrent")

    def test_slot_b_waits_while_partitions_are_still_being_added(self):
        self.boot(NANO_BOOT0001)
        self.disk("nvme0n1", NANO_NVME, {1: "APP"}, nsid="1", eui=NANO_EUI)
        self.during_settle(self.late_partition(NANO_NVME, "nvme0n1", 3, "A_kernel"))
        self.assert_wait("no usable APP_b on nvme0n1")
        # Once the table stops growing without an APP_b, the disk is not A/B.
        self.assert_root("nvme0n1p1", "bootcurrent")

    def test_applets_missing_from_the_initramfs_are_not_found(self):
        missing = self.available - INITRD_APPLETS
        named = sorted(name for name in missing if re.fullmatch(r"[A-Za-z_]\w*", name))
        result = subprocess.run(
            [BUSYBOX, "sh", "-c", f'. {self.helper_stubs}\nfor n in {" ".join(named)}; do\n'
             '    "$n" --help >/dev/null 2>&1; [ $? -eq 127 ] || echo "$n"\ndone'],
            env=self.env, capture_output=True, text=True, check=False)
        self.assertEqual(result.stdout, "", "these ran although the initramfs lacks them")
        # A function cannot take these names, so the scripts must not use them.
        for name in missing - set(named):
            for source in (HELPER, PREBOOT, INIT):
                self.assertNotRegex(source.read_text(),
                                    rf"(?<![\w.-]){re.escape(name)}(?![\w.-])", name)

    def test_duplicate_slot_partition_is_not_usable(self):
        self.boot(NANO_BOOT0001)
        self.disk("nvme0n1", NANO_NVME, {1: "APP", 2: "APP_b", 3: "APP_b"}, nsid="1",
                  eui=NANO_EUI)
        self.assert_wait("no usable APP_b on nvme0n1")
        self.assert_root("nvme0n1p1", "bootcurrent", slot="")

    def test_partition_without_device_node_waits(self):
        self.boot(NANO_BOOT0001)
        self.nano(nodes=False)
        self.assert_wait("no usable APP_b on nvme0n1", bootdrive="/dev/nvme0n1",
                         fallbacks="bootdrive")


class PrebootTests(InitramfsCase):
    def setUp(self):
        super().setUp()
        self.preboot_with("/dev/nvme0n1")

    def preboot_with(self, bootdrive, findroot=None):
        text = PREBOOT.read_text().replace("@@BOOTDRIVE@@", bootdrive)
        text = self.replace(text, "/proc/cmdline", f"{self.root}/proc/cmdline")
        text = self.replace(text, "/sys/firmware/efi/efivars", str(self.efivars))
        (self.root / "preboot.in").write_text(text)
        self.preboot = self.install(self.root / "preboot.in", "preboot",
                                    findroot=findroot or self.helper, devdir=self.dev)

    def run_preboot(self):
        driver = self.root / "driver"
        driver.write_text(f'. {self.stub_file}\nrootdev=""\nopt="rw"\nwait=""\nfstype="auto"\n'
                          f'. {self.preboot}\necho "result: $rootdev $opt $wait $fstype"\n')
        return subprocess.run([BUSYBOX, "sh", str(driver)], env=self.env, capture_output=True,
                              text=True, timeout=120, check=False)

    def assert_cadence(self):
        # Every timing in the preboot is a pass count at half a second per pass.
        self.assertLessEqual({call for call in self.calls() if call.startswith("sleep ")},
                             {"sleep 0.5"})

    def assert_resolves(self, device, source, sleeps, opt="rw", wait="", fstype="auto"):
        result = self.run_preboot()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"[OK: {device} ({source})]", result.stdout)
        self.assertEqual(result.stdout.splitlines()[-1], f"result: {device} {opt} {wait} {fstype}")
        self.assertEqual(self.sleeps(), sleeps)
        self.assert_cadence()

    def assert_gives_up(self):
        result = self.run_preboot()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("[OK", result.stdout)
        self.assertIn("[FAIL: no APP", result.stdout)
        # An empty rootdev sends /init to its own failure handling.
        self.assertEqual(result.stdout.splitlines()[-1], "result:  rw  auto")
        self.assertEqual(self.sleeps(), PREBOOT_PASSES)
        self.assert_cadence()
        return result.stdout

    def test_resolves_on_the_first_pass(self):
        self.cmdline("console=ttyTCU0 ro rootwait rootfstype=ext4")
        self.boot(NANO_BOOT0001)
        self.nano()
        self.assert_resolves(f"{self.dev}/nvme0n1p2", "bootcurrent", 0, "ro", "yes", "ext4")

    def test_firmware_slot_a(self):
        self.boot(NANO_BOOT0001, slot=SLOT_A)
        self.nano()
        self.assert_resolves(f"{self.dev}/nvme0n1p1", "bootcurrent", 0)

    def test_slot_suffix_argument_still_searches(self):
        self.cmdline("boot.slot_suffix=_b")
        self.boot(NANO_BOOT0001, slot=SLOT_A)
        self.nano()
        self.assert_resolves(f"{self.dev}/nvme0n1p2", "bootcurrent", 0)

    def test_slot_a_suffix_argument_is_app(self):
        self.cmdline("boot.slot_suffix=_a")
        self.boot(NANO_BOOT0001, slot=SLOT_B)
        self.nano()
        self.assert_resolves(f"{self.dev}/nvme0n1p1", "bootcurrent", 0)

    def test_slot_b_never_takes_app_while_app_b_is_being_added(self):
        self.boot(NANO_BOOT0001)
        self.disk("nvme0n1", NANO_NVME, {1: "APP"}, nsid="1", eui=NANO_EUI)
        self.during_settle(self.late_partition(NANO_NVME, "nvme0n1", 2, "APP_b"))
        self.assert_resolves(f"{self.dev}/nvme0n1p2", "bootcurrent", 0)

    def test_late_enumeration(self):
        self.boot(NANO_BOOT0001)
        self.nano(link=False, nodes=False)
        self.after_sleep(3, f"ln -s ../{NANO_NVME} {self.root}/sys/block/nvme0n1\n"
                            f"ln -s {BLOCK_DEVICE} {self.dev}/nvme0n1p2")
        self.assert_resolves(f"{self.dev}/nvme0n1p2", "bootcurrent", 3)

    def test_undecided_option_uses_bootdrive_at_once(self):
        self.boot(NANO_BOOT0000)
        self.nano()
        self.assert_resolves(f"{self.dev}/nvme0n1p2", "bootdrive", 0)

    def test_decided_boot_disk_gets_five_seconds_before_bootdrive(self):
        self.preboot_with("/dev/mmcblk0")
        self.boot(NANO_BOOT0001)
        self.agx_emmc()
        self.assert_resolves(f"{self.dev}/mmcblk0p2", "bootdrive", 10)

    def test_late_boot_disk_beats_a_ready_bootdrive(self):
        self.preboot_with("/dev/mmcblk0")
        self.boot(NANO_BOOT0001)
        self.agx_emmc()
        self.nano(link=False)
        self.after_sleep(3, f"ln -s ../{NANO_NVME} {self.root}/sys/block/nvme0n1")
        self.assert_resolves(f"{self.dev}/nvme0n1p2", "bootcurrent", 3)

    def test_boot_disk_decoded_wrongly_falls_back_to_the_single_disk_after_a_minute(self):
        self.preboot_with("")
        self.boot(load_option(VENDOR, memory_mapped(0x14160000), nvme_node(eui="11" * 8), END))
        self.nano()
        self.assert_resolves(f"{self.dev}/nvme0n1p2", "single-disk", 120)

    def test_lost_boot_disk_never_falls_back_to_another_medium(self):
        # Booting the stale eMMC would confirm the trial slot, so the unit could never roll back.
        self.preboot_with("")
        self.boot(NANO_BOOT0001)
        self.agx_emmc()
        self.assertIn("boot disk not found", self.assert_gives_up())

    def test_single_wendyos_disk_after_settling(self):
        self.preboot_with("")
        self.boot(NANO_BOOT0000)
        self.nano()
        self.assert_resolves(f"{self.dev}/nvme0n1p2", "single-disk", 30)

    def test_root_argument_after_five_seconds(self):
        self.preboot_with("")
        self.boot(NANO_BOOT0000)
        self.node("sda1")
        (self.root / "blkid-out").write_text(f"{self.dev}/sda1: PARTUUID=\"0b8b5f1c\"\n")
        for argument in ("PARTUUID=0b8b5f1c", "UUID=5e3c0d4a-1f7b-4c1e-9d2a-7f1e0c3b8a6d",
                         "LABEL=rootfs", "PARTLABEL=APP", f"{self.dev}/sda1"):
            with self.subTest(argument=argument):
                (self.root / "calls").unlink(missing_ok=True)
                self.cmdline(f"root={argument}")
                self.assert_resolves(f"{self.dev}/sda1", "root=", 10)
                lookups = {call for call in self.calls() if call.startswith("blkid")}
                expected = set() if argument.startswith("/") else {f"blkid -t {argument} -l"}
                self.assertEqual(lookups, expected)

    def test_root_argument_must_be_a_block_device(self):
        self.preboot_with("")
        self.boot(NANO_BOOT0000)
        (self.dev / "sda1").write_text("")
        self.cmdline(f"root={self.dev}/sda1")
        self.assert_gives_up()

    def test_missing_helper_waits_then_uses_root_argument(self):
        self.preboot_with("/dev/nvme0n1", findroot=self.root / "missing")
        self.boot(NANO_BOOT0001)
        self.nano()
        self.assertIn(f"no answer from {self.root}/missing", self.assert_gives_up())
        (self.root / "calls").unlink()
        self.cmdline(f"root={self.dev}/nvme0n1p1")
        self.assert_resolves(f"{self.dev}/nvme0n1p1", "root=", 10)

    def test_malformed_helper_answers_are_rejected(self):
        (self.dev / "file").write_text("")
        self.node("nvme0n1p2")
        answers = [f"root {self.dev}/file bootcurrent",
                   f"root {self.dev}/nvme0n1p2 somewhere",
                   "nvme0n1p2 bootcurrent",
                   f"root {self.dev}/nvme0n1p2  bootcurrent",
                   f"root {self.dev}/nvme0n1p2 bootcurrent extra",
                   f"root {self.dev}/../dev/nvme0n1p2 bootcurrent",
                   f"root {BLOCK_DEVICE} bootcurrent",
                   f"root {self.dev}/nvme0n1p2 bootcurrent\nroot {self.dev}/nvme0n1p2 bootcurrent"]
        for answer in answers:
            with self.subTest(answer=answer):
                (self.root / "calls").unlink(missing_ok=True)
                fake = self.root / "fake-helper"
                fake.write_text(f"#!{BUSYBOX} sh\nprintf '%s\\n' '{answer}'\n")
                fake.chmod(0o755)
                self.preboot_with("/dev/nvme0n1", findroot=fake)
                self.assert_gives_up()

    def test_no_fallback_to_the_build_time_partition(self):
        # Slot A's APP must never stand in for a slot B partition that is not there yet.
        self.boot(NANO_BOOT0001)
        self.nano(nodes=False)
        self.node("nvme0n1p1")
        output = self.assert_gives_up()
        progress = [line for line in output.splitlines() if line.startswith("Waiting for")]
        self.assertEqual(len(progress), PREBOOT_PASSES // 10)
        self.assertIn("Waiting for APP_b: no usable APP_b on nvme0n1", progress[0])
        self.assertNotIn("TNSPEC_BOOTDEV", PREBOOT.read_text())


class InitTests(InitramfsCase):
    def setUp(self):
        super().setUp()
        (self.root / "etc").mkdir()
        preboot = PREBOOT.read_text().replace("@@BOOTDRIVE@@", "/dev/nvme0n1")
        preboot = self.replace(preboot, "/proc/cmdline", f"{self.root}/proc/cmdline")
        preboot = self.replace(preboot, "/sys/firmware/efi/efivars", str(self.efivars))
        (self.root / "preboot.in").write_text(preboot)
        self.install(self.root / "preboot.in", "etc/platform-preboot", findroot=self.helper,
                     devdir=self.dev)
        text = INIT.read_text()
        for old, new in (("PATH=/sbin:/bin:/usr/sbin:/usr/bin", f"PATH={self.bin}"),
                         ("find /sys ", f"find {self.root}/sys "),
                         ("/etc/platform-pre", f"{self.root}/etc/platform-pre"),
                         ("/proc/cmdline", f"{self.root}/proc/cmdline"),
                         ("/sys/firmware/efi/efivars/RootfsRedundancyLevel",
                          f"{self.efivars}/RootfsRedundancyLevel"),
                         ("/mnt", f"{self.root}/mnt"),
                         ("exec switch_root", f"exec {self.bin}/switch_root"),
                         ("exec sh", f"exec {self.bin}/sh")):
            text = self.replace(text, old, new)
        (self.root / "init.sh").write_text(text)
        self.init = self.root / "init"
        self.init.write_text(f". {self.stub_file}\n. {self.root}/init.sh\n")
        self.boot(NANO_BOOT0001)
        self.nano()

    def run_init(self, mount_mode, redundancy):
        (self.root / "mount-mode").write_text(mount_mode)
        if redundancy is not None:
            self.efivar("RootfsRedundancyLevel", NVIDIA, redundancy)
        result = subprocess.run([BUSYBOX, "sh", str(self.init)], env=self.env,
                                capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return [call for call in self.calls() if not call.startswith("mount -t proc")]

    def root_mounts(self, calls):
        return [call for call in calls
                if call == f"mount -t auto -o rw {self.dev}/nvme0n1p2 {self.root}/mnt"]

    def test_mounts_the_found_root_and_switches(self):
        calls = self.run_init("ok", REDUNDANCY_ON)
        self.assertEqual(len(self.root_mounts(calls)), 1)
        self.assertEqual(calls[-1], f"switch_root {self.root}/mnt /sbin/init")
        self.assertFalse([call for call in calls if call.startswith(("reboot", "sh", "umount"))])

    def test_failed_mounts_reboot_an_ab_unit(self):
        calls = self.run_init("fail", REDUNDANCY_ON)
        self.assertEqual(len(self.root_mounts(calls)), 5)
        self.assertEqual(calls[-3:], ["sleep 5", "reboot -f", "sh "])

    def test_failed_mounts_drop_to_a_shell_without_ab(self):
        for redundancy in (REDUNDANCY_OFF, None):
            with self.subTest(redundancy=redundancy):
                (self.root / "calls").unlink(missing_ok=True)
                for entry in self.efivars.glob("RootfsRedundancyLevel-*"):
                    entry.unlink()
                calls = self.run_init("fail", redundancy)
                self.assertEqual(len(self.root_mounts(calls)), 5)
                self.assertEqual(calls[-1], "sh ")
                self.assertFalse([call for call in calls if call.startswith("reboot")])

    def test_no_root_found_ends_in_the_failure_policy(self):
        (self.root / "sys/block/nvme0n1").unlink()
        for cmdline in ("", "rootwait"):
            for redundancy, ending in ((REDUNDANCY_ON, ["sleep 5", "reboot -f", "sh "]),
                                       (None, ["mount -t auto -o rw  " + f"{self.root}/mnt",
                                               "sleep 1.0", "sh "])):
                with self.subTest(cmdline=cmdline, redundancy=redundancy):
                    self.cmdline(cmdline)
                    (self.root / "calls").unlink(missing_ok=True)
                    for entry in self.efivars.glob("RootfsRedundancyLevel-*"):
                        entry.unlink()
                    calls = self.run_init("fail", redundancy)
                    self.assertEqual(calls.count(f"mount -t auto -o rw  {self.root}/mnt"), 5)
                    self.assertEqual(calls[-len(ending):], ending)

    def test_rootwait_does_not_wait_for_an_unresolved_root_token(self):
        (self.root / "sys/block/nvme0n1").unlink()
        self.cmdline("root=PARTUUID=0b8b5f1c rootwait")
        calls = self.run_init("fail", REDUNDANCY_ON)
        self.assertEqual(calls.count(f"mount -t auto -o rw PARTUUID=0b8b5f1c {self.root}/mnt"), 5)
        self.assertEqual(calls[-3:], ["sleep 5", "reboot -f", "sh "])

    def test_rootwait_still_waits_for_an_explicit_root(self):
        (self.root / "sys/block/nvme0n1").unlink()
        self.cmdline(f"root={self.dev}/sda1 rootwait")
        self.after_sleep(PREBOOT_PASSES + 5, f"ln -s {BLOCK_DEVICE} {self.dev}/sda1")
        calls = self.run_init("ok", REDUNDANCY_ON)
        self.assertIn(f"mount -t auto -o rw {self.dev}/sda1 {self.root}/mnt", calls)
        self.assertEqual(calls[-1], f"switch_root {self.root}/mnt /sbin/init")

    def test_root_without_init_is_a_failed_mount(self):
        calls = self.run_init("no-init", REDUNDANCY_ON)
        self.assertEqual(len(self.root_mounts(calls)), 5)
        self.assertEqual(calls.count(f"umount {self.root}/mnt"), 5)
        self.assertEqual(calls[-2:], ["reboot -f", "sh "])
        self.assertFalse([call for call in calls if call.startswith("switch_root")])


class BbappendTests(unittest.TestCase):
    def setUp(self):
        self.text = BBAPPEND.read_text()

    def test_changes_apply_to_orin_only(self):
        # Every statement but the search path carries the Orin override.
        in_function = continued = False
        for line in self.text.splitlines():
            if in_function:
                in_function = line != "}"
                continue
            if continued or not line.strip() or line.startswith("#"):
                continued = continued and line.endswith("\\")
                continue
            continued = line.endswith("\\")
            in_function = line.endswith("{")
            name = re.match(r"(?:python\s+|fakeroot\s+)*([^\s=?:+.(]+(?::[\w-]+)*)", line).group(1)
            if name != "FILESEXTRAPATHS:prepend":
                self.assertRegex(name, r":tegra234(:|$)", line)
        self.assertNotIn("tegra264", self.text)

    def test_drift_guard_pins_the_upstream_scripts(self):
        self.assertIn(UPSTREAM_INIT_SHA256, self.text)
        self.assertIn(UPSTREAM_PREBOOT_SHA256, self.text)

    def run_install(self, upstream_unchanged=True, preboot=None, bootdrive="/dev/nvme0n1"):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        image, unpack = Path(tmp.name) / "image", Path(tmp.name) / "unpack"
        (image / "etc").mkdir(parents=True)
        unpack.mkdir()
        for name in ("init-boot.sh", "platform-preboot.sh"):
            (unpack / name).write_text("upstream\n")
        for source in (HELPER, INIT, PREBOOT):
            shutil.copy(source, unpack / source.name)
        if preboot is not None:
            (unpack / PREBOOT.name).write_text(preboot)
        body = re.search(r"^do_install:append:tegra234\(\) \{\n(.*?)^\}", self.text,
                         re.S | re.M).group(1)
        values = {"D": image, "UNPACKDIR": unpack, "sysconfdir": "/etc",
                  "base_sbindir": "/usr/sbin", "TNSPEC_BOOTDEV": "nvme0n1p1",
                  "TEGRA_MINIMAL_INIT_BOOTDRIVE": bootdrive}
        script = re.sub(r"\$\{(\w+)\}", lambda m: str(values[m.group(1)]), body)
        if upstream_unchanged:
            # The stand-ins for meta-tegra's scripts take the place of their pinned checksums.
            digest = hashlib.sha256(b"upstream\n").hexdigest()
            script = script.replace(UPSTREAM_INIT_SHA256, digest)
            script = script.replace(UPSTREAM_PREBOOT_SHA256, digest)
        # bitbake runs shell tasks with -e and provides bbfatal.
        result = subprocess.run(["sh", "-ec", 'bbfatal() { echo "$*" >&2; exit 1; }\n' + script],
                                text=True, capture_output=True, check=False)
        return result, image

    def test_installs_the_wendyos_scripts(self):
        result, image = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((image / "init").read_text(), INIT.read_text())
        self.assertEqual((image / "usr/sbin/wendyos-find-root").read_text(), HELPER.read_text())
        preboot = (image / "etc/platform-preboot").read_text()
        self.assertIn("\nbootdrive=/dev/nvme0n1\n", preboot)
        self.assertNotIn("@@", preboot)
        # The preboot runs the helper from where the recipe installs it.
        findroot = re.search(r"^findroot=(.*)$", preboot, re.M).group(1)
        self.assertEqual((image / findroot.lstrip("/")).read_text(), HELPER.read_text())
        modes = {path: stat.S_IMODE((image / path).stat().st_mode)
                 for path in ("init", "etc/platform-preboot", "usr/sbin/wendyos-find-root")}
        self.assertEqual(modes, {"init": 0o755, "etc/platform-preboot": 0o644,
                                 "usr/sbin/wendyos-find-root": 0o755})

    def test_changed_upstream_scripts_fail_the_build(self):
        result, _ = self.run_install(upstream_unchanged=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("upstream init-boot.sh changed", result.stderr)

    def test_bootdrive_must_be_empty_or_a_disk_node(self):
        for bootdrive in ("", "/dev/mmcblk0", "/dev/nvme0n1", "/dev/sda"):
            with self.subTest(bootdrive=bootdrive):
                result, image = self.run_install(bootdrive=bootdrive)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"\nbootdrive={bootdrive}\n",
                              (image / "etc/platform-preboot").read_text())
        for bootdrive in ("nvme0n1", "/dev/", "/dev/disk/by-partlabel/APP",
                          "/dev/nvme0n1p1", "/dev/mmcblk0p1", "/dev/sda1"):
            with self.subTest(bootdrive=bootdrive):
                result, _ = self.run_install(bootdrive=bootdrive)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("TEGRA_MINIMAL_INIT_BOOTDRIVE must be", result.stderr)

    def test_unsubstituted_token_fails_the_build(self):
        result, _ = self.run_install(preboot=PREBOOT.read_text() + "x=@@UNKNOWN@@\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("@@ token", result.stderr)


if __name__ == "__main__":
    unittest.main()
