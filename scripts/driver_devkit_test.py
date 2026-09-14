"""Run the actual CI devkit selection block with isolated curl fixtures."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]


def manifest(version, kernel):
    return {"versions": {version: {"devkit": {"kernel_version": kernel}}}}


class DevkitTests(unittest.TestCase):
    def select(self, pr=None, public=None, prefix="pr/262/", want="pr-262"):
        # Exercise the shipped YAML shell, not a second implementation of it.
        workflow = (ROOT / ".github/workflows/drivers.yml").read_text()
        start = workflow.index('          for dev in "${DEVICES[@]}"; do\n')
        end = workflow.index('            echo "${dev}: devkit ', start)
        script = ('set -euo pipefail\nDEVICES=(jetson-agx-thor)\n'
                  + textwrap.dedent(workflow[start:end])
                  + '  printf "SELECTED=%s\\n" "$sel"\ndone\n')
        with tempfile.TemporaryDirectory() as tmp:
            curl = Path(tmp) / "curl"
            curl.write_text('''#!/bin/sh
for url do :; done
printf '%s\\n' "$url" >> "$FETCH_LOG"
case "$url" in
    */pr/262/*) result=$PR_MANIFEST ;;
    *) result=$PUBLIC_MANIFEST ;;
esac
[ -n "$result" ] || exit 22
printf '%s\\n' "$result"
''')
            curl.chmod(0o755)
            log = Path(tmp) / "fetches"
            env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"],
                       PUBLIC_BASE="https://fixture.invalid", PREFIX=prefix,
                       WANT_VERSION=want, FETCH_LOG=str(log),
                       PR_MANIFEST=json.dumps(pr) if pr is not None else "",
                       PUBLIC_MANIFEST=json.dumps(public) if public is not None else "")
            result = subprocess.run(["bash", "-c", script], env=env,
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            selected = [line.removeprefix("SELECTED=") for line in result.stdout.splitlines()
                        if line.startswith("SELECTED=")]
            return (json.loads(selected[0]) if selected else None), log.read_text().splitlines()

    def test_first_driver_only_pr_uses_public_devkit(self):
        selected, urls = self.select(public=manifest("0.19.1", "6.8"))
        self.assertEqual(selected["version"], "0.19.1")
        self.assertEqual(len(urls), 2)

    def test_repeated_driver_only_pr_uses_public_devkit(self):
        pr = {"versions": {"pr-262": {"extensions": [{"name": "wendyos-hello"}]}}}
        selected, urls = self.select(pr=pr, public=manifest("0.19.1", "6.8"))
        self.assertEqual(selected["devkit"]["kernel_version"], "6.8")
        self.assertEqual(len(urls), 2)

    def test_own_pr_devkit_takes_precedence(self):
        selected, urls = self.select(pr=manifest("pr-262", "6.9"),
                                     public=manifest("0.19.1", "6.8"))
        self.assertEqual(selected["devkit"]["kernel_version"], "6.9")
        self.assertEqual(len(urls), 1)

    def test_public_run_does_not_fetch_twice(self):
        selected, urls = self.select(public={"versions": {}}, prefix="")
        self.assertIsNone(selected)
        self.assertEqual(len(urls), 1)

    def test_no_devkit_skips_device(self):
        selected, urls = self.select(pr={"versions": {}}, public={"versions": {}})
        self.assertIsNone(selected)
        self.assertEqual(len(urls), 2)

    def test_requested_version_wins_over_newest(self):
        public = manifest("0.19.1", "6.8")
        public["versions"].update(manifest("0.19.2", "6.9")["versions"])
        selected, _ = self.select(public=public, prefix="", want="0.19.1")
        self.assertEqual(selected["version"], "0.19.1")


if __name__ == "__main__":
    unittest.main()
