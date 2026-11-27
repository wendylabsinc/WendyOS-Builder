"""Static checks on the U-Boot A/B boot scripts (Raspberry Pi and Rockchip).

The boot script runs before any userspace and OTA never rewrites it, so a mistake shows
up only as a board that will not boot. Each family's script is rendered with the
real renderer and checked against the files it must agree with: the wks slot
numbers, fw_env.config's size and the U-Boot config fragment.

Run: python3 -m unittest scripts/boot_ab_script_test.py
"""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "recipes-bsp/wendyos-boot-ab/files"
RENDER = SHARED / "boot-ab-render.sh"
HEAD = SHARED / "boot-ab-slot.cmd.in"
RPI_TAIL = ROOT / "meta-rpi-extensions/recipes-bsp/rpi-u-boot-scr/files/boot-ab-rpi.cmd.in"
RK_TAIL = ROOT / "meta-rockchip-extensions/recipes-bsp/wendyos-boot-scr/files/boot-ab-rockchip.cmd.in"
RK_UBOOT_CFG = ROOT / "meta-rockchip-extensions/recipes-bsp/u-boot/files/wendyos-boot.cfg"
RK_COMMON = ROOT / "conf/machine/include/rockchip-common-wendyos.inc"
RK_RECIPE = ROOT / "meta-rockchip-extensions/recipes-bsp/wendyos-boot-scr/wendyos-boot-scr.bb"
RK_FW_ENV = ROOT / "meta-rockchip-extensions/recipes-bsp/wendyos-fw-env/wendyos-fw-env.bb"
RPI_FW_ENV = ROOT / "meta-rpi-extensions/recipes-bsp/wendyos-fw-env/files/fw_env.config"
RPI_UBOOT_APPEND = ROOT / "meta-rpi-extensions/recipes-bsp/u-boot/u-boot_%.bbappend"
SHARED_INC = ROOT / "recipes-bsp/wendyos-boot-ab/wendyos-boot-ab.inc"
IMAGE_INCS = {"rpi": ROOT / "conf/distro/include/rpi-image.inc",
              "rockchip": ROOT / "conf/distro/include/rockchip-image.inc"}

# The env contract of the wendyos-update ubootenv connector.
PERSISTED = ("wendyos_boot_slot", "wendyos_upgrade_available", "bootcount", "bootlimit")

FAMILIES = {
    "rpi": {
        "tail": RPI_TAIL,
        "wks": ROOT / "meta-rpi-extensions/files/wic/rpi-wendy-ab.wks",
        "values": {"WENDYOS_UBOOT_ENV_SIZE": "0x4000", "WENDYOS_SD_MMC_DEV": "0",
                   "KERNEL_IMAGETYPE": "Image", "KERNEL_BOOTCMD": "booti",
                   "WENDYOS_UBOOT_FDT_HIGH": ""},
    },
    "rockchip": {
        "tail": RK_TAIL,
        "wks": ROOT / "meta-rockchip-extensions/files/wic/rockchip-wendy-ab.wks",
        "values": {"WENDYOS_UBOOT_ENV_SIZE": "0x8000", "WENDYOS_SD_MMC_DEV": "1",
                   "KERNEL_IMAGETYPE": "Image",
                   "WENDYOS_ROCKCHIP_DTB": "rk3588s-orangepi-5-pro.dtb",
                   "WENDYOS_CONSOLE_ARGS": "console=tty0"},
    },
}
SLOTS = {"WENDYOS_ROOTFS_PART_A": "3", "WENDYOS_ROOTFS_PART_B": "4", "WENDYOS_BOOTLIMIT": "1"}


def render(tail, values, head=HEAD):
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "boot.cmd"
        args = [f"{k}={v}" for k, v in {**SLOTS, **values}.items()]
        result = subprocess.run(["sh", str(RENDER), str(head), str(tail), str(out), *args],
                                text=True, capture_output=True, check=False)
        return result, (out.read_text() if out.exists() else "")


def commands(script):
    """The script without comments and blank lines: prose must not satisfy a check."""
    return "\n".join(line for line in script.splitlines()
                     if line.strip() and not line.lstrip().startswith("#"))


def table_partitions(wks):
    """Labels of the wks partitions that get a partition-table entry, in order."""
    labels = []
    for line in wks.read_text().splitlines():
        if not line.startswith("part ") or "--no-table" in line:
            continue
        labels.append(re.search(r"--label\s+(\S+)", line).group(1))
    return labels


class RenderTests(unittest.TestCase):
    def test_every_family_renders_with_nothing_left_over(self):
        for family, spec in FAMILIES.items():
            with self.subTest(family=family):
                result, script = render(spec["tail"], spec["values"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotRegex(script, r"@@[A-Za-z0-9_]+@@")

    def test_a_missing_value_fails_the_render(self):
        values = dict(FAMILIES["rockchip"]["values"])
        del values["WENDYOS_ROCKCHIP_DTB"]
        result, _ = render(RK_TAIL, values)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WENDYOS_ROCKCHIP_DTB", result.stderr)

    def test_a_value_sed_cannot_take_fails_the_render(self):
        values = {**FAMILIES["rockchip"]["values"], "WENDYOS_CONSOLE_ARGS": "a|b"}
        result, _ = render(RK_TAIL, values)
        self.assertNotEqual(result.returncode, 0)


class EnvContractTests(unittest.TestCase):
    def setUp(self):
        self.head = commands(HEAD.read_text())

    def test_every_persisted_variable_has_a_first_boot_default(self):
        for name in PERSISTED:
            with self.subTest(var=name):
                self.assertRegex(self.head, rf'if test "\${{{name}}}" = ""; then setenv {name} ')

    def test_env_import_takes_exactly_the_contract(self):
        # uboot.env, then uboot-backup.env when uboot.env is missing or damaged.
        imports = re.findall(r"env import -c \S+ \S+ ([^;\n]*)", self.head)
        self.assertEqual(len(imports), 2)
        for imported in imports:
            self.assertEqual(imported.split(), list(PERSISTED))

    def test_backup_is_refreshed_before_the_trial_writes(self):
        # A power cut during a trial write must find the pre-write state in the
        # backup, so every backup write comes before the trial section.
        trial = self.head.index("setexpr bootcount ${bootcount} + 1")
        writes = [m.start() for m in re.finditer(r"fatwrite \S+ \S+ \S+ uboot-backup.env", self.head)]
        self.assertEqual(len(writes), 2)
        self.assertTrue(all(w < trial for w in writes))

    def test_a_missing_or_damaged_uboot_env_is_rewritten(self):
        # Only a uboot.env that imported cleanly is left alone; fw_setenv on
        # Linux cannot edit a damaged one.
        self.assertIn('if test "${wendyos_env_src}" = "primary"; then', self.head)
        # A valid uboot.env without the slot (fw_setenv's default-env rebuild)
        # must not override the backup.
        self.assertIn('if test -n "${wendyos_boot_slot}"; then setenv wendyos_env_src primary; fi', self.head)
        self.assertRegex(self.head, r"(?m)^elif run wendyos_saveenv; then$")
        self.assertNotIn("test ! -e", self.head)

    def test_saveenv_size_matches_fw_env_config(self):
        for family, spec in FAMILIES.items():
            with self.subTest(family=family):
                _, script = render(spec["tail"], spec["values"])
                sizes = set(re.findall(r"env export -c -s (0x[0-9a-fA-F]+)", script))
                sizes |= set(re.findall(r"fatwrite \S+ \S+ \S+ uboot(?:-backup)?\.env (0x[0-9a-fA-F]+)", script))
                sizes |= set(re.findall(r"cmp\.b \S+ \S+ (0x[0-9a-fA-F]+)", script))
                sizes |= set(re.findall(r"setexpr wendyos_env_bak \S+ \+ (0x[0-9a-fA-F]+)", script))
                self.assertEqual(sizes, {spec["values"]["WENDYOS_UBOOT_ENV_SIZE"]})
        fw = [line.split() for line in RPI_FW_ENV.read_text().splitlines()
              if line.strip() and not line.startswith("#")]
        self.assertEqual(fw, [["/boot/uboot.env", "0x0000", FAMILIES["rpi"]["values"]["WENDYOS_UBOOT_ENV_SIZE"]]])
        # Rockchip writes fw_env.config from the variable the boot script uses.
        self.assertIn("/boot/uboot.env 0x0000 %s", RK_FW_ENV.read_text())
        self.assertIn('"${WENDYOS_UBOOT_ENV_SIZE}" > ${D}${sysconfdir}/fw_env.config', RK_FW_ENV.read_text())

    def test_images_ship_the_default_env(self):
        # Without /etc/u-boot-initial-env, fw_setenv fails on a damaged
        # uboot.env (exit 243) and every OTA stops at the slot switch.
        for family, inc in IMAGE_INCS.items():
            with self.subTest(family=family):
                installs = " ".join(re.findall(r'IMAGE_INSTALL:append = "([^"]*)"', inc.read_text()))
                self.assertIn("wendyos-fw-env", installs.split())
                self.assertIn("u-boot-default-env", installs.split())
        # meta-raspberrypi's u-boot-env also carries an fw_env.config.
        self.assertRegex(RPI_UBOOT_APPEND.read_text(),
                         r"do_install:append:rpi \(\) \{\n    rm -f \$\{D\}\$\{sysconfdir\}/fw_env.config\n\}")

    def test_rockchip_env_size_comes_from_the_machine_include(self):
        self.assertIn('WENDYOS_UBOOT_ENV_SIZE = "0x8000"', RK_COMMON.read_text())

    def test_slot_numbers_match_the_wks(self):
        for family, spec in FAMILIES.items():
            with self.subTest(family=family):
                labels = table_partitions(spec["wks"])
                self.assertEqual(labels, ["boot", "config", "rootfsA", "rootfsB", "data"])
                self.assertEqual(labels.index("rootfsA") + 1, int(SLOTS["WENDYOS_ROOTFS_PART_A"]))
                self.assertEqual(labels.index("rootfsB") + 1, int(SLOTS["WENDYOS_ROOTFS_PART_B"]))

    def test_shared_defaults_match_the_test(self):
        inc = SHARED_INC.read_text()
        for name, value in SLOTS.items():
            self.assertIn(f'{name} ?= "{value}"', inc)

    def test_bootlimit_stays_where_hex_and_decimal_agree(self):
        # setexpr writes hex, test -gt reads decimal: 9 + 1 = "a".
        self.assertIn("1 <= int(limit) <= 8", SHARED_INC.read_text())


class RockchipTailTests(unittest.TestCase):
    def setUp(self):
        _, script = render(RK_TAIL, FAMILIES["rockchip"]["values"])
        self.body = commands(script)

    def test_kernel_and_dtb_come_from_the_selected_slot(self):
        slot = r"\$\{wendyos_if\} \$\{wendyos_dev\}:\$\{wendyos_root_part\}"
        self.assertRegex(self.body, rf"ext4load {slot} \$\{{fdt_addr_r\}} /boot/rk3588s-orangepi-5-pro.dtb")
        self.assertRegex(self.body, rf"ext4load {slot} \$\{{kernel_addr_r\}} /boot/Image")
        self.assertIn("booti ${kernel_addr_r} - ${fdt_addr_r}", self.body)

    def test_a_failed_boot_resets(self):
        self.assertTrue(self.body.rstrip().endswith("reset"))

    def test_bootargs_name_the_slot_and_never_hang_a_trial(self):
        # panic=10 and a bounded rootwait turn a bad trial slot into a reset,
        # which the next boot counts toward the fall-back.
        bootargs = re.search(r'setenv bootargs "(.*)"', self.body).group(1)
        self.assertEqual(bootargs, "console=tty0 root=${wendyos_root} rootwait=60 rw panic=10")

    def test_release_console_ends_on_the_vt_and_debug_adds_the_uart_last(self):
        recipe = RK_RECIPE.read_text()
        self.assertIn('WENDYOS_ROCKCHIP_DEBUG_CONSOLE ?= "console=${RK_CONSOLE_DEVICE},${RK_CONSOLE_BAUD}n8"', recipe)
        self.assertRegex(recipe, r'WENDYOS_ROCKCHIP_CONSOLE_ARGS = "console=tty0\$\{@')

    def test_sd_fallback_is_the_sd_card_alias(self):
        # A '?=' after the shared include's '?=' default would never take effect.
        self.assertRegex(RK_RECIPE.read_text(), r'(?m)^WENDYOS_SD_MMC_DEV = "1"$')
        self.assertIn('WENDYOS_SD_MMC_DEV ?= "0"', SHARED_INC.read_text())


class RockchipUBootTests(unittest.TestCase):
    def setUp(self):
        self.cfg = dict(line.split("=", 1) for line in RK_UBOOT_CFG.read_text().splitlines()
                        if line.startswith("CONFIG_"))

    def test_the_script_commands_are_enabled(self):
        # setexpr counts trial boots, fatwrite saves uboot.env, itest checks its
        # size, cmp compares its backup, part reads PARTUUIDs.
        for symbol in ("CONFIG_CMD_SETEXPR", "CONFIG_FAT_WRITE", "CONFIG_CMD_ITEST", "CONFIG_CMD_MEMORY",
                       "CONFIG_CMD_PART", "CONFIG_CMD_NVME"):
            self.assertEqual(self.cfg.get(symbol), "y", symbol)

    def script_name(self):
        return re.search(r'^WENDYOS_ROCKCHIP_BOOT_SCRIPT = "([^"]+)"', RK_COMMON.read_text(), re.M).group(1)

    def test_bootcmd_tries_sd_then_emmc_then_nvme(self):
        bootcmd, name = self.cfg["CONFIG_BOOTCOMMAND"], self.script_name()
        order = [bootcmd.index(probe) for probe in
                 (f"test -e mmc 1:1 {name}", f"test -e mmc 0:1 {name}", "nvme scan")]
        self.assertEqual(order, sorted(order))
        self.assertIn(f"load ${{devtype}} ${{devnum}}:1 ${{scriptaddr}} {name} && source ${{scriptaddr}}", bootcmd)

    def test_the_script_name_is_family_specific_and_shipped_under_it(self):
        # A Pi card's boot.scr must never be sourced on a Rockchip board.
        name = self.script_name()
        self.assertNotEqual(name, "boot.scr")
        self.assertNotIn("boot.scr", self.cfg["CONFIG_BOOTCOMMAND"])
        self.assertIn('IMAGE_BOOT_FILES = "${WENDYOS_ROCKCHIP_BOOT_SCRIPT}"', RK_COMMON.read_text())
        self.assertIn("${DEPLOYDIR}/${WENDYOS_ROCKCHIP_BOOT_SCRIPT}", RK_RECIPE.read_text())

    def test_uboot_env_size_bounds_the_saved_env(self):
        # env export -c is bounded by ENV_SIZE, not by -s: a bigger ENV_SIZE
        # would save an oversized env truncated instead of failing the save.
        size = re.search(r'^WENDYOS_UBOOT_ENV_SIZE = "(0x[0-9a-f]+)"', RK_COMMON.read_text(), re.M).group(1)
        self.assertEqual(self.cfg["CONFIG_ENV_SIZE"], size)

    def test_no_autoboot_prompt(self):
        self.assertEqual(self.cfg["CONFIG_BOOTDELAY"], "-2")


if __name__ == "__main__":
    unittest.main()
