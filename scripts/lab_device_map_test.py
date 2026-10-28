"""Hold build.yml's lab-board map to the layers that actually exist.

A PR's hardware run is dispatched to one lab board per SoC family it touches.
The mapping lives in two places in build.yml -- the paths-filter entries that
name a family, and the step that turns each family into a board -- and both are
hand-written against the directory layout. A pattern that matches nothing is
indistinguishable from a PR that touched nothing: the run goes green having
tested the wrong board. So assert the patterns hit real paths, and that no
board-carrying layer is left without a family.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github' / 'workflows' / 'build.yml'

# Layers with no board in the lab: nothing to dispatch, so no family.
NO_LAB_BOARD = ('meta-vm-extensions', 'meta-qemu-extensions', 'meta-x86-extensions')

# Machines with no board in the lab, by conf/machine filename prefix.
NO_LAB_MACHINE = ('vm-', 'qemuarm', 'genericx86')


def _families_from_filter():
    """{family: [glob, ...]} from the paths-filter block, in file order."""
    text = WORKFLOW.read_text()
    block = re.search(r'\n          filters: \|\n(.*?)\n      - ', text, re.S)
    assert block, 'paths-filter block not found in build.yml'
    families, current = {}, None
    for line in block.group(1).splitlines():
        name = re.match(r'^            ([a-z]+):\s*$', line)
        if name:
            current = name.group(1)
            families[current] = []
            continue
        pat = re.match(r"^              - '(.+)'\s*$", line)
        if pat and current:
            families[current].append(pat.group(1))
    return families


def _family_boards():
    """{family: board} from the board-selection step's if-lines."""
    text = WORKFLOW.read_text()
    pairs = re.findall(
        r'if \[\[ "\$\{([A-Z]+):-\}" == "true" \]\]; then BOARDS\+=\(([a-z0-9-]+)\); fi',
        text)
    return {env.lower(): board for env, board in pairs}


def _matches(path, pattern):
    """The subset of picomatch the patterns here use.

    '*' stays inside one segment, '**' spans them. Order matters: the
    wildcard-directory form ('meta-tegra-extensions*/**') also ends in '/**'.
    """
    regex = re.escape(pattern).replace(r'\*\*', '\x00').replace(r'\*', '[^/]*')
    regex = regex.replace('\x00', '.*')
    return re.fullmatch(regex, path) is not None


class LabDeviceMap(unittest.TestCase):
    def setUp(self):
        self.families = _families_from_filter()
        self.boards = _family_boards()
        self.paths = [
            str(p.relative_to(ROOT))
            for p in ROOT.rglob('*')
            if p.is_file() and '.git/' not in str(p)
        ]

    def test_every_family_has_a_board(self):
        """A filter nobody dispatches on is dead config."""
        for family in self.boards:
            self.assertIn(family, self.families,
                          f'{family} selects a board but has no paths-filter entry')

    def test_every_pattern_matches_something(self):
        """A pattern matching nothing silently skips its board."""
        for family, patterns in self.families.items():
            if family not in self.boards:
                continue  # 'drivers'/'os' are the build gate, not the lab map
            for pattern in patterns:
                self.assertTrue(
                    any(_matches(p, pattern) for p in self.paths),
                    f'{family} pattern {pattern!r} matches no file in the tree')

    def test_every_extension_layer_has_a_family(self):
        """A new SoC layer must be mapped, or declared boardless.

        This is the one that catches a sibling layer: meta-tegra-extensions-jp7
        is not matched by 'meta-tegra-extensions/**'.
        """
        lab_patterns = [p for f, pats in self.families.items()
                        if f in self.boards for p in pats]
        for layer in sorted(d.name for d in ROOT.iterdir()
                            if d.is_dir() and d.name.startswith('meta-')):
            if layer in NO_LAB_BOARD:
                continue
            probe = f'{layer}/conf/layer.conf'
            self.assertTrue(
                any(_matches(probe, pat) for pat in lab_patterns),
                f'{layer} is matched by no lab family; map it or add it to NO_LAB_BOARD')

    def test_every_machine_conf_has_a_family(self):
        """Same drift guard for a new board's conf/machine entry."""
        lab_patterns = [p for f, pats in self.families.items()
                        if f in self.boards for p in pats]
        machines = sorted((ROOT / 'conf' / 'machine').glob('*.conf'))
        self.assertTrue(machines, 'no conf/machine/*.conf found')
        for conf in machines:
            if conf.name.startswith(NO_LAB_MACHINE):
                continue
            rel = f'conf/machine/{conf.name}'
            self.assertTrue(
                any(_matches(rel, pat) for pat in lab_patterns),
                f'{rel} is matched by no lab family; map it or add it to NO_LAB_MACHINE')

    def test_boards_are_distinct(self):
        """Two families on one board would halve the run without saying so."""
        boards = list(self.boards.values())
        self.assertEqual(len(boards), len(set(boards)), f'duplicate board: {boards}')


if __name__ == '__main__':
    unittest.main()
