"""Guard Git-patched kernel release identities against wall-clock patch dates.

Qualcomm's LOCALVERSION_AUTO includes the patched Git commit in the release.
Apply the real patch hunks to reconstructed textual preimages, twice at different
times, using OpenEmbedded's git-am options. This tests patch metadata and Git
identity, not kernel compilation; omitted source lines are fixture placeholders.
"""
import collections
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCH_DIRS = (
    'meta-qcom-extensions/recipes-kernel/linux/linux-qcom-next',
    'meta-arduino-extensions/recipes-kernel/linux/linux-qcom-next',
)


def preimages(patch):
    files = collections.defaultdict(dict)
    context_free_paths = set()
    filename = None
    old_left = new_left = 0
    for line in patch.read_text().splitlines(keepends=True):
        if old_left or new_left:
            if line == '\n':
                line = ' \n'
            if line.startswith((' ', '-')):
                files[filename][position] = line[1:]
                position += 1
                old_left -= 1
            if line.startswith((' ', '+')):
                new_left -= 1
            if line.startswith(' '):
                has_context = True
            if not old_left and not new_left and not has_context:
                context_free_paths.add(filename)
        elif line.startswith('--- a/'):
            filename = line[6:].strip().split('\t')[0]
        elif line.startswith('@@ '):
            match = re.match(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', line)
            if not match or not filename:
                raise ValueError(f'Unsupported hunk in {patch}: {line}')
            position = int(match[1])
            old_left, new_left = int(match[2] or 1), int(match[4] or 1)
            has_context = False
    if old_left or new_left or not files:
        raise ValueError(f'Incomplete patch fixture: {patch}')
    # A context-free replacement must not gain special EOF treatment because
    # its reconstructed fixture happens to end there. Keep real append-at-EOF
    # patches at their boundary, while giving these replacements a file tail.
    for filename in context_free_paths:
        lines = files[filename]
        lines[max(lines) + 8] = '/* omitted trailing kernel source */\n'
    return files


class KernelPatchDatesTest(unittest.TestCase):
    def test_patch_commit_identity_is_reproducible(self):
        patches = [p for directory in PATCH_DIRS for p in sorted((ROOT / directory).glob('*.patch'))]
        patches += sorted((ROOT / 'recipes-kernel/linux/bluetooth-le-pending').glob('*qcom.patch'))
        self.assertGreaterEqual(len(patches), 6)
        env = os.environ | {
            'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
            'GIT_AUTHOR_NAME': 'OpenEmbedded', 'GIT_AUTHOR_EMAIL': 'oe.patch@oe',
            'GIT_COMMITTER_NAME': 'OpenEmbedded', 'GIT_COMMITTER_EMAIL': 'oe.patch@oe',
        }
        for key in ('GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE'):
            env.pop(key, None)

        def git(work, *args, fixed=False):
            dates = {key: '2001-01-01T00:00:00 +0000' for key in ('GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE')} if fixed else {}
            result = subprocess.run(['git', *map(str, args)], cwd=work, env=env | dates,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertEqual(result.returncode, 0, result.stdout)
            return result.stdout.strip()

        def apply(work, patch):
            git(work, 'am', '--committer-date-is-author-date', '-3', '--keep-cr', '--no-scissors', '-p1', patch)
            return git(work, 'rev-parse', 'HEAD')

        with tempfile.TemporaryDirectory() as tmp:
            cases = []
            for index, patch in enumerate(patches):
                work = Path(tmp) / str(index)
                work.mkdir()
                git(work, 'init', '-q')
                for name, lines in preimages(patch).items():
                    target = work / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(''.join(lines.get(i, f'/* omitted source line {i} */\n') for i in range(1, max(lines)+1)))
                git(work, 'add', '.')
                git(work, 'commit', '-qm', 'Fixed preimage', fixed=True)
                base = git(work, 'rev-parse', 'HEAD')
                cases.append((work, patch, base, apply(work, patch)))
            # Undated mail patches use Git's real clock even with GIT_AUTHOR_DATE
            # exported. Cross a wall-clock second before replaying the same input.
            time.sleep(1.1)
            for work, patch, base, first in cases:
                with self.subTest(patch=str(patch.relative_to(ROOT))):
                    git(work, 'reset', '--hard', base)
                    self.assertEqual(first, apply(work, patch),
                                     'Patch commit changed: provide a fixed Date header')


if __name__ == '__main__':
    unittest.main()
