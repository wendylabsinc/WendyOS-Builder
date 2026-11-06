#!/usr/bin/env python3
"""Check which Orin units the bootloader capsule applies to, as UEFI decides it.

Runs the BUP generator append (tegra_tnspec_legacy.bbclass) on upstream-format
generator output with the machine confs' names, rebuilds each image TnSpec as
tegra-flash-helper.sh does, and matches it with a port of edk2-nvidia's
FwPackageLib against TegraPlatformSpec/CompatSpec strings read from real boards.
"""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BBAPPEND = ROOT / "meta-tegra-extensions/recipes-bsp/uefi/tegra-uefi-capsules_%.bbappend"
CLASS = ROOT / "meta-tegra-extensions/classes/tegra_tnspec_legacy.bbclass"
IMAGE_INC = ROOT / "conf/distro/include/tegra-image.inc"
CONFS = {
    "nano": ROOT / "conf/machine/jetson-orin-nano-devkit-wendyos.conf",
    "agx": ROOT / "conf/machine/jetson-agx-orin-devkit-wendyos.conf",
}
THOR_CONF = ROOT / "conf/machine/jetson-agx-thor-devkit-nvme-wendyos.conf"

# meta-tegra de0a5a23: orin-nano.inc:1-14, tegra234.inc:15-19, p3737-0000-p3701-0005.conf:6-7.
BOARDS = {
    "nano": {"TEGRA_BOARDID": "3767", "TEGRA_FAB": "RC1", "TEGRA_BOARDSKU": "0005", "TEGRA_BOARDREV": "B.4",
             "TEGRA_BUPGEN_SPECS": "fab=000;boardsku=0005;boardrev=;chipsku=00:00:00:D5;bup_type=bl "
                                   "fab=000;boardsku=0005;boardrev=;bup_type=kernel"},
    "agx": {"TEGRA_BOARDID": "3701", "TEGRA_FAB": "TS4", "TEGRA_BOARDSKU": "0005", "TEGRA_BOARDREV": "C.0",
            "TEGRA_BUPGEN_SPECS": "fab=300;boardsku=0005;boardrev=;chipsku=00:00:00:D0;bup_type=bl "
                                  "fab=300;boardsku=0005;boardrev=;bup_type=kernel"},
}
COMMON = {"TEGRA_CHIPREV": "0", "NVIDIA_CHIP": "0x23", "LNXFILE": "boot.img",
          "BUP_PAYLOAD_DIR": "payloads_t23x",
          "TEGRA_BUPGEN_STRIP_CMD": 'sed -e"/<filename>.*esp.img/d" flash.xml.in > flash-stripped.xml.in'}
# generate_bup_payload.sh of a merged Orin Nano build whose capsule carried all three names.
BUILT_NANO_SCRIPT = """#!/bin/bash
sed -e"/<filename>.*esp.img/d" flash.xml.in > flash-stripped.xml.in
rm -rf signed multi_signed rollback.bin payloads_t23x
export BOARDID=3767
export localbootfile=boot.img
export CHIPREV=0
export CHIPID=0x23
MACHINE=jetson-orin-nano-wendyos FAB="000" BOARDSKU="0005" BOARDREV="" CHIP_SKU="00:00:00:D5" ./tegra-flash-helper.sh --sign --bup --bup-type bl ./flash-stripped.xml.in "$@"
MACHINE=jetson-orin-nano-devkit-wendyos FAB="000" BOARDSKU="0005" BOARDREV="" CHIP_SKU="00:00:00:D5" ./tegra-flash-helper.sh --sign --bup --bup-type bl ./flash-stripped.xml.in "$@"
MACHINE=jetson-orin-nano-devkit-nvme-wendyos FAB="000" BOARDSKU="0005" BOARDREV="" CHIP_SKU="00:00:00:D5" ./tegra-flash-helper.sh --sign --bup --bup-type bl ./flash-stripped.xml.in "$@"
MACHINE=jetson-orin-nano-wendyos FAB="000" BOARDSKU="0005" BOARDREV="" CHIP_SKU="00:00:00:D5" ./tegra-flash-helper.sh --sign --bup --bup-type kernel ./flash-stripped.xml.in "$@"
MACHINE=jetson-orin-nano-devkit-wendyos FAB="000" BOARDSKU="0005" BOARDREV="" CHIP_SKU="00:00:00:D5" ./tegra-flash-helper.sh --sign --bup --bup-type kernel ./flash-stripped.xml.in "$@"
MACHINE=jetson-orin-nano-devkit-nvme-wendyos FAB="000" BOARDSKU="0005" BOARDREV="" CHIP_SKU="00:00:00:D5" ./tegra-flash-helper.sh --sign --bup --bup-type kernel ./flash-stripped.xml.in "$@"
"""

# Every machine name a fielded unit can carry in its write-once TegraPlatformSpec.
LEGACY = {
    "nano": ["jetson-orin-nano-devkit-wendyos", "jetson-orin-nano-devkit-nvme-wendyos"],
    "agx": ["jetson-agx-orin-devkit-emmc-wendyos", "jetson-agx-orin-devkit-nvme-wendyos"],
}
# Names a fresh merged install must not share: legacy, renamed, stock meta-tegra and Thor.
FORBIDDEN = {
    "jetson-orin-nano-devkit-wendyos", "jetson-orin-nano-devkit-nvme-wendyos",
    "jetson-agx-orin-devkit-emmc-wendyos", "jetson-agx-orin-devkit-nvme-wendyos",
    "jetson-agx-orin-devkit-wendyos", "jetson-orin-nano-devkit-edgeos",
    "jetson-orin-nano-devkit-nvme-edgeos", "jetson-orin-nano-devkit", "jetson-orin-nano-devkit-nvme",
    "jetson-agx-orin-devkit", "jetson-agx-thor-devkit-nvme-wendyos",
}
# efivars read on the bench (TegraPlatformSpec, TegraPlatformCompatSpec).
BENCH = {
    "nano": ("3767-300-0005-T.1-1-0-jetson-orin-nano-devkit-nvme-wendyos-",
             "3767--0005--1--jetson-orin-nano-devkit-nvme-wendyos-"),
    "agx": ("3701-501-0005-G.0-1-0-jetson-agx-orin-devkit-emmc-wendyos-",
            "3701--0005--1--jetson-agx-orin-devkit-emmc-wendyos-"),
}
# TnSpecs of today's split capsules: Nano NVMe and AGX eMMC read out of shipped tegra-bl.cap files,
# the other two in their format.
SPLIT_CAPSULES = {
    "nano": ["3767-000-0005--1-0-jetson-orin-nano-devkit-nvme-wendyos-",
             "3767-000-0005--1-0-jetson-orin-nano-devkit-wendyos-"],
    "agx": ["3701-300-0005--1-0-jetson-agx-orin-devkit-emmc-wendyos-",
            "3701-300-0005--1-0-jetson-agx-orin-devkit-nvme-wendyos-"],
}
# t23x_bl_table entries with BOARD_SPECIFIC=1; FwImageNames.c requires most of them.
BOARD_SPECIFIC = ["BCT", "BCT_A", "BCT_B", "mb1", "MB1_BCT", "MEM_BCT", "mb2", "bpmp-fw", "bpmp-fw-dtb",
                  "cpu-bootloader", "dce-fw", "BCT-boot-chain_backup", "secondary_gpt_backup", "VER",
                  "secondary_gpt"]
TNSPEC_LENGTH = 128  # FW_PACKAGE_TNSPEC_LENGTH; tegra-flash-helper.sh refuses longer specs

# tegra-bl.cap measured on the bench: images shared by every spec, then one board-specific set per spec.
CAPSULE_HEADER, ENTRY_HEADER = 2957, 184
COMMON_IMAGES, COMMON_ENTRIES = 5121408, 14
PER_SPEC = {"nano": 6432605, "agx": 6613805}
ESP_FREE = 64401 * 1024  # smaller of the two bench ESPs
STAGING_MARGIN = 1 << 20  # wendyos-update keeps this free on top of the capsule


def conf_value(path, name):
    """A plain `NAME = "value"` assignment; anything weaker could be overridden elsewhere."""
    match = re.search(rf'^{name} = "([^"]*)"$', path.read_text(), re.M)
    return match.group(1) if match else None


def check_tnspec(s1, s2):
    """FwPackageLib.c FwPackageCheckTnSpec: same token count, empty tokens are wildcards."""
    t1, t2 = s1.split("-"), s2.split("-")
    if len(t1) != len(t2):
        return "INVALID_PARAMETER"
    for a, b in zip(t1, t2):
        if a and b and a != b:
            return "NOT_FOUND"
    return "SUCCESS"


def image_index(entries, name, full_spec, compat_spec, production=True):
    """FwPackageLib.c FwPackageGetImageIndex: a full-spec hit wins at once, else the first compat hit."""
    found = None
    for index, (entry_name, mode, spec) in enumerate(entries):
        if entry_name != name:
            continue
        if mode != 0 and mode != (2 if production else 1):
            continue
        if spec:
            if full_spec is not None and check_tnspec(full_spec, spec) == "SUCCESS":
                return index
            if compat_spec is not None and check_tnspec(compat_spec, spec) != "SUCCESS":
                continue
        if found is None:
            found = index
    return found


def gen_compat_spec(boardspec):
    """meta-tegra uefi_common.func.in gen_compat_spec for the 3701 and 3767 devkit SKUs."""
    boardid, fab, boardsku, boardrev, fuselevel, chiprev = boardspec.split("-")
    if boardid == "3701":
        if boardsku == "0000":
            fab = "000" if re.match(r"^([012][0-9][0-9]|TS|EB)", fab) else "300"
        elif boardsku in ("0004", "0005", "0008"):
            fab = ""
    elif boardid == "3767":
        if boardsku in ("0000", "0002"):
            fab = fab if re.match(r"^(TS|EB)", fab) else "000"
        else:
            fab = ""
    else:
        return ""
    return f"{boardid}-{fab}-{boardsku}--{fuselevel}-"


def unit(boardspec, machine):
    """The (TegraPlatformSpec, TegraPlatformCompatSpec) pair setup-nv-boot-control writes."""
    return f"{boardspec}-{machine}-", f"{gen_compat_spec(boardspec)}-{machine}-"


def names(board):
    return conf_value(CONFS[board], "TNSPEC_MACHINE"), conf_value(CONFS[board], "WENDYOS_TNSPEC_LEGACY_MACHINES")


def upstream_script(board, machine):
    """generate_bup_payload.sh as upstream's tegraflash_generate_bupgen_script writes it
    (meta-tegra de0a5a23 image_types_tegra.bbclass:525-551): one line per spec, all for one name."""
    values = dict(COMMON, **BOARDS[board])
    lines = ["#!/bin/bash", values["TEGRA_BUPGEN_STRIP_CMD"],
             f"rm -rf signed multi_signed rollback.bin {values['BUP_PAYLOAD_DIR']}",
             f"export BOARDID={values['TEGRA_BOARDID']}", f"export localbootfile={values['LNXFILE']}",
             f"export CHIPREV={values['TEGRA_CHIPREV']}", f"export CHIPID={values['NVIDIA_CHIP']}"]
    chipsku = ""
    for entry in values["TEGRA_BUPGEN_SPECS"].split():
        spec = dict(item.split("=", 1) for item in entry.split(";"))
        chipsku = spec.get("chipsku", chipsku)  # upstream's eval never clears it between specs
        buptype_arg = f"--bup-type {spec['bup_type']}" if spec.get("bup_type") else ""
        lines.append(f'MACHINE={machine} FAB="{spec["fab"]}" BOARDSKU="{spec["boardsku"]}" '
                     f'BOARDREV="{spec["boardrev"]}" CHIP_SKU="{chipsku}" ./tegra-flash-helper.sh '
                     f'--sign --bup {buptype_arg} ./flash-stripped.xml.in "$@"')
    return "\n".join(lines) + "\n"


def class_function(header):
    return re.search(rf"^{re.escape(header)} \{{\n(.*?)^\}}\n", CLASS.read_text(), re.S | re.M).group(1)


def run_append(board, script, legacy=None):
    """Run the class's append where bitbake puts it: at the end of upstream's function, after it wrote $outfile."""
    current, fielded = names(board)
    values = {"TNSPEC_MACHINE": current,
              "WENDYOS_TNSPEC_LEGACY_MACHINES": fielded if legacy is None else legacy}
    body = re.sub(r"\$\{(\w+)\}", lambda m: values[m.group(1)],
                  class_function("tegraflash_generate_bupgen_script:append:tegra234()"))
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "generate_bup_payload.sh"
        out.write_text(script)
        result = subprocess.run(
            ["sh", "-ec", 'bbfatal() { echo "$*" >&2; exit 1; }\n'
             f'gen() {{\n    local outfile="${{1:-./generate_bup_payload.sh}}"\n{body}}}\ngen {out}'],
            capture_output=True, text=True, check=False)
        return result, out.read_text(), sorted(path.name for path in Path(tmp).iterdir())


def bbappend_function(header):
    return re.search(rf"^{re.escape(header)} \{{\n(.*?)^\}}\n", BBAPPEND.read_text(), re.S | re.M).group(1)


def run_capsule_check(board, capsule):
    """Run the bbappend's do_compile append against a tegra-bl.cap holding these bytes."""
    current, legacy = names(board)
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "tegra-bl.cap").write_bytes(capsule)
        values = {"TNSPEC_MACHINE": current, "WENDYOS_TNSPEC_LEGACY_MACHINES": legacy, "B": tmp}
        body = re.sub(r"\$\{(\w+)\}", lambda m: values[m.group(1)],
                      bbappend_function("do_compile:append:tegra234()"))
        return subprocess.run(["bash", "-ec", f'bbfatal() {{ echo "$*" >&2; exit 1; }}\n{body}'],
                              capture_output=True, text=True, check=False)


def render_specs(board):
    """Generate the board's script and rebuild each TnSpec as tegra-flash-helper.sh:1013 does."""
    result, script, _ = run_append(board, upstream_script(board, names(board)[0]))
    assert result.returncode == 0, result.stderr
    env = dict(re.findall(r"^export (\w+)=(\S*)$", script, re.M))
    specs = []
    for line in script.splitlines():
        m = re.match(r'^MACHINE=(\S+) FAB="([^"]*)" BOARDSKU="([^"]*)" BOARDREV="([^"]*)" '
                     r'CHIP_SKU="[^"]*" \./tegra-flash-helper\.sh --sign --bup (?:--bup-type (\w+) )?', line)
        if m:
            machine, fab, sku, rev, bup_type = m.groups()
            specs.append((bup_type, f"{env['BOARDID']}-{fab}-{sku}-{rev}-1-{env['CHIPREV']}-{machine}-"))
    return specs


def package(spec_list):
    """A BUP with every board-specific bl image once per spec and the common images untagged."""
    entries = [(name, 2, spec) for spec in spec_list for name in BOARD_SPECIFIC]
    entries += [(name, 0, "") for name in ("secure-os", "spe-fw", "rce-fw", "adsp-fw", "mb2rf")]
    return entries


def applies(spec_list, spec_pair):
    """The machine name of the board-specific set a unit picks, or None when it rejects the capsule."""
    entries = package(spec_list)
    picks = {name: image_index(entries, name, *spec_pair) for name in BOARD_SPECIFIC}
    if any(index is None for index in picks.values()):
        return None
    machines = {entries[index][2] for index in picks.values()}
    assert len(machines) == 1, machines
    return machines.pop()


class PortTests(unittest.TestCase):
    def test_compat_port_reproduces_the_bench_efivars(self):
        for board, (full, compat) in BENCH.items():
            boardspec = "-".join(full.split("-")[:6])
            machine = full[len(boardspec) + 1:-1]
            self.assertEqual(unit(boardspec, machine), (full, compat), board)

    def test_todays_split_capsules_match_only_their_own_medium(self):
        for board, (full, compat) in BENCH.items():
            hits = [spec for spec in SPLIT_CAPSULES[board] if applies([spec], (full, compat))]
            self.assertEqual(len(hits), 1, board)
            self.assertTrue(hits[0].endswith(full.split("-", 6)[6]), board)

    def test_an_empty_machine_token_never_matches(self):
        # The count rule runs before the wildcard rule: one empty token is not a whole name.
        for board, pair in BENCH.items():
            prefix = SPLIT_CAPSULES[board][0].split("-jetson")[0]
            self.assertIsNone(applies([prefix + "--"], pair), board)


class CapsuleTests(unittest.TestCase):
    def specs(self, board, bup_type="bl"):
        return [spec for kind, spec in render_specs(board) if kind == bup_type]

    def test_machine_confs_name_every_fielded_unit(self):
        for board in BOARDS:
            current, legacy = names(board)
            self.assertIsNotNone(current, board)
            self.assertIsNotNone(legacy, board)
            self.assertLessEqual(set(LEGACY[board]), set(legacy.split()), board)

    def test_one_spec_per_name_in_every_payload_type(self):
        for board in BOARDS:
            current, legacy = names(board)
            for kind in ("bl", "kernel"):
                machines = [spec.split("-", 6)[6][:-1] for spec in self.specs(board, kind)]
                self.assertEqual(sorted(machines), sorted([current] + legacy.split()), (board, kind))

    def test_every_fielded_and_new_unit_takes_the_capsule(self):
        for board in BOARDS:
            specs = self.specs(board)
            boardspec = "-".join(BENCH[board][0].split("-")[:6])
            for machine in LEGACY[board] + [names(board)[0]]:
                with self.subTest(board=board, machine=machine):
                    picked = applies(specs, unit(boardspec, machine))
                    self.assertIsNotNone(picked)
                    self.assertTrue(picked.endswith(f"-{machine}-"))

    def test_fab_and_revision_of_the_unit_do_not_matter(self):
        fabs = {"nano": ["000", "100", "300", "TS1", "EB2"], "agx": ["300", "400", "500", "501", "TS4"]}
        for board in BOARDS:
            specs = self.specs(board)
            boardid, _, sku = BENCH[board][0].split("-")[:3]
            for fab in fabs[board]:
                for rev in ("A.0", "G.0", "T.1"):
                    pair = unit(f"{boardid}-{fab}-{sku}-{rev}-1-0", names(board)[0])
                    self.assertIsNotNone(applies(specs, pair), (board, fab, rev))

    def test_split_capsules_never_match_a_merged_install(self):
        for board in BOARDS:
            boardspec = "-".join(BENCH[board][0].split("-")[:6])
            pair = unit(boardspec, names(board)[0])
            for spec in SPLIT_CAPSULES[board]:
                self.assertIsNone(applies([spec], pair), (board, spec))

    def test_new_names_are_new_and_whole(self):
        for board in BOARDS:
            current, legacy = names(board)
            self.assertNotIn(current, FORBIDDEN)
            self.assertNotIn(current, legacy.split())
            self.assertRegex(current, r"^[a-z0-9]+(-[a-z0-9]+)*$")
            # A token count unlike every legacy name: the count rule alone rejects old capsules.
            self.assertNotIn(current.count("-"), {m.count("-") for m in LEGACY[board]})
            for spec in self.specs(board):
                self.assertLess(len(spec), TNSPEC_LENGTH)

    def test_no_capsule_crosses_boards(self):
        for board in BOARDS:
            other = "agx" if board == "nano" else "nano"
            boardspec = "-".join(BENCH[other][0].split("-")[:6])
            for machine in LEGACY[other] + [names(other)[0]]:
                self.assertIsNone(applies(self.specs(board), unit(boardspec, machine)), (board, machine))

    def test_only_tegra234_gets_the_append(self):
        text = CLASS.read_text()
        self.assertEqual(re.findall(r"(?m)^(tegraflash_generate_bupgen_script\S*)\(\)", text),
                         ["tegraflash_generate_bupgen_script:append:tegra234"])
        self.assertNotIn("tegraflash_generate_bupgen_script", BBAPPEND.read_text())
        self.assertRegex(BBAPPEND.read_text(), r"(?m)^do_compile:append:tegra234\(\)")
        for name in ("TNSPEC_MACHINE", "WENDYOS_TNSPEC_LEGACY_MACHINES"):
            self.assertNotRegex(THOR_CONF.read_text(), rf"(?m)^{name}\b")

    def test_the_capsule_and_the_bundle_share_the_append(self):
        # The bundle's generate_bup_payload.sh must sign the names the capsule signs.
        for path in (BBAPPEND, IMAGE_INC):
            self.assertRegex(path.read_text(), r"(?m)^inherit tegra_tnspec_legacy$", path.name)

    def test_capsule_fits_the_esp(self):
        for board in BOARDS:
            count = len(self.specs(board))
            size = (CAPSULE_HEADER + ENTRY_HEADER * (COMMON_ENTRIES + len(BOARD_SPECIFIC) * count)
                    + COMMON_IMAGES + PER_SPEC[board] * count)
            self.assertLessEqual(size + STAGING_MARGIN, ESP_FREE, (board, count, size))


class AppendTests(unittest.TestCase):
    def test_upstream_fixture_is_what_upstream_writes(self):
        # The fixture's lines for the new name, as a merged Nano build wrote them.
        current = names("nano")[0]
        built = [line for line in BUILT_NANO_SCRIPT.splitlines()
                 if not line.startswith("MACHINE=") or line.startswith(f"MACHINE={current} ")]
        self.assertEqual(upstream_script("nano", current).splitlines(), built)

    def test_the_append_gives_the_built_lines(self):
        # Only the order differs: each tegra-flash-helper.sh --bup run rebuilds its payload type
        # from every spec signed so far (l4t_bup_gen.func), so the last run of a type has them all.
        result, script, _ = run_append("nano", upstream_script("nano", names("nano")[0]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(script.splitlines()), sorted(BUILT_NANO_SCRIPT.splitlines()))

    def test_every_upstream_line_is_repeated_once_per_legacy_name(self):
        for board in BOARDS:
            current, legacy = names(board)
            upstream = upstream_script(board, current)
            result, script, files = run_append(board, upstream)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(files, ["generate_bup_payload.sh"], "the append leaves a temp file behind")
            self.assertTrue(script.startswith(upstream), board)
            specs = [line for line in upstream.splitlines() if line.startswith("MACHINE=")]
            expected = [line.replace(f"MACHINE={current} ", f"MACHINE={name} ", 1)
                        for name in legacy.split() for line in specs]
            self.assertEqual(script[len(upstream):].splitlines(), expected, board)

    def test_only_lines_for_the_whole_name_are_repeated(self):
        current = names("nano")[0]
        upstream = upstream_script("nano", current)
        longer = upstream_script("nano", f"{current}-x").splitlines()[-1] + "\n"
        result, script, _ = run_append("nano", upstream + longer, legacy="legacy-name")
        self.assertEqual(result.returncode, 0, result.stderr)
        added = [line.replace(f"MACHINE={current} ", "MACHINE=legacy-name ", 1)
                 for line in upstream.splitlines() if line.startswith("MACHINE=")]
        self.assertEqual(script, upstream + longer + "\n".join(added) + "\n")

    def test_no_legacy_names_leave_the_script_alone(self):
        upstream = upstream_script("nano", names("nano")[0])
        result, script, _ = run_append("nano", upstream, legacy="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(script, upstream)

    def test_a_script_without_the_name_fails_the_build(self):
        # Upstream changing its line format must not ship a capsule without the legacy specs.
        for script in (upstream_script("nano", "jetson-orin-nano"),
                       upstream_script("nano", names("nano")[0]).replace("MACHINE=", "MACHINE=\"")):
            with self.subTest(script=script.splitlines()[-1][:40]):
                result, _, _ = run_append("nano", script)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no MACHINE=jetson-orin-nano-wendyos line", result.stderr)


class BuildGuardTests(unittest.TestCase):
    @staticmethod
    def capsule(specs):
        # TnSpecs sit in NUL-padded fields between binary image data.
        return b"\x00\x01NVIDIA\xff".join(spec.encode().ljust(128, b"\x00") for spec in specs)

    def test_capsule_check_needs_every_name(self):
        for board in BOARDS:
            specs = [spec for kind, spec in render_specs(board) if kind == "bl"]
            result = run_capsule_check(board, self.capsule(specs))
            self.assertEqual(result.returncode, 0, (board, result.stderr))
            current, legacy = names(board)
            for machine in [current] + legacy.split():
                with self.subTest(board=board, machine=machine):
                    result = run_capsule_check(board, self.capsule(s for s in specs if not s.endswith(f"-{machine}-")))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"no TnSpec for {machine}", result.stderr)

    def test_capsule_check_wants_whole_names(self):
        # A longer name that ends or starts with the expected one is another unit's spec.
        for board in BOARDS:
            specs = [spec for kind, spec in render_specs(board) if kind == "bl"]
            current, legacy = names(board)
            for machine in [current] + legacy.split():
                for other in (f"x-{machine}", f"{machine}-x"):
                    with self.subTest(board=board, machine=machine, other=other):
                        swapped = [s.replace(f"-{machine}-", f"-{other}-") if s.endswith(f"-{machine}-") else s
                                   for s in specs]
                        self.assertIn(f"-{machine}-".encode(), self.capsule(swapped))
                        result = run_capsule_check(board, self.capsule(swapped))
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(f"no TnSpec for {machine}", result.stderr)


if __name__ == "__main__":
    unittest.main()
