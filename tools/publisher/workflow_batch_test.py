#!/usr/bin/env python3
"""Run the checked-in publishing steps with local cloud/publisher substitutes."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BUILD_WORKFLOW = ROOT / ".github/workflows/build.yml"
DRIVER_WORKFLOW = ROOT / ".github/workflows/drivers.yml"


def step_script(name, workflow=BUILD_WORKFLOW):
    lines = workflow.read_text().splitlines()
    start = lines.index(f"      - name: {name}")
    start = lines.index("        run: |", start) + 1
    script = []
    for line in lines[start:]:
        if line.strip() and not line.startswith("          "):
            break
        script.append(line[10:])
    return "\n".join(script)


class WorkflowBatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ("bin", "run", "manifest-entries", "cloud", "wendyos/tools/publisher"):
            (self.root / directory).mkdir(parents=True)
        self.env = dict(os.environ, GITHUB_WORKSPACE=str(self.root),
                        RUNNER_TEMP=str(self.root / "run"), PR_NUMBER="270",
                        PUBLIC_BASE="https://test.invalid", TEST_ROOT=str(self.root))
        self.env["PATH"] = str(self.root / "bin") + os.pathsep + os.environ["PATH"]
        self.executable("bin/gcloud", "#!/bin/sh\necho test-token\n")
        self.executable("bin/go", "#!/bin/sh\nexit 0\n")
        self.executable("bin/curl", '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
path = Path(os.environ["TEST_ROOT"]) / "cloud" / sys.argv[-1].rsplit("/", 1)[-1]
if not path.exists():
    sys.exit(22)
print(path.read_text())
''')
        self.executable("run/publisher", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
batch = json.loads(Path(args[args.index("--master-manifest-batch") + 1]).read_text())
with (Path(os.environ["TEST_ROOT"]) / "calls.jsonl").open("a") as f:
    f.write(json.dumps({"args": args, "batch": batch}) + "\\n")
''')
        self.write_json("cloud/master.json", {"devices": {}})

    def executable(self, name, text):
        path = self.root / name
        path.write_text(text)
        path.chmod(0o755)

    def write_json(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def run_step(self, name, workflow=BUILD_WORKFLOW):
        result = subprocess.run([os.environ.get("PUBLISHER_TEST_BASH", "bash"), "-c",
                                 step_script(name, workflow)],
                                cwd=ROOT, env=self.env, text=True,
                                capture_output=True, timeout=20)
        calls = self.root / "calls.jsonl"
        return result, [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

    def entry(self, name, device, nightly=False, **extra):
        self.write_json(f"manifest-entries/{name}.json",
                        dict(device=device, version="new", nightly=nightly, **extra))

    def test_pr_batches_all_devices_and_storage_variants(self):
        self.entry("iq", "iq", stability="experimental")
        self.entry("pi-sd", "pi", storage="sd")
        self.entry("pi-nvme", "pi", storage="nvme")
        result, calls = self.run_step("Update PR master manifest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["args"][-4:], ["--pr", "270", "--access-token", "test-token"])
        self.assertEqual(len(calls[0]["batch"]), 3)
        self.assertTrue(all(row["nightly"] for row in calls[0]["batch"]))
        self.assertEqual(calls[0]["batch"][0]["stability"], "experimental")

    def test_driver_index_batches_unique_devices(self):
        self.env["MATRIX"] = json.dumps({"include": [
            {"device": "jetson-agx-thor"},
            {"device": "jetson-agx-orin"},
            {"device": "jetson-agx-thor"},
        ]})
        result, calls = self.run_step("Update PR master index", DRIVER_WORKFLOW)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["args"][-4:],
                         ["--pr", "270", "--access-token", "test-token"])
        self.assertEqual(calls[0]["batch"], [
            {"device": "jetson-agx-orin", "version": "pr-270",
             "nightly": True, "stability": "stable"},
            {"device": "jetson-agx-thor", "version": "pr-270",
             "nightly": True, "stability": "stable"},
        ])

    def test_release_preserves_driver_gate_and_channels(self):
        self.entry("held", "held", nightly=True)
        self.entry("stable", "stable", nightly=False)
        self.entry("nightly-sd", "nightly", nightly=True, storage="sd")
        self.entry("nightly-nvme", "nightly", nightly=True, storage="nvme")
        self.write_json("cloud/master.json", {"devices": {
            "held": {"latest": "no-drivers", "latest_nightly": "with-drivers"},
            "stable": {"latest": "no-drivers", "latest_nightly": "with-drivers"},
        }})
        for device in ("held", "stable", "nightly"):
            self.write_json(f"cloud/{device}.json", {"versions": {
                "no-drivers": {}, "with-drivers": {"extensions": [{"name": "driver"}]}, "new": {},
            }})
        result, calls = self.run_step("Update master manifest")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("leaving latest on with-drivers", result.stdout)
        self.assertEqual(len(calls), 1)
        self.assertNotIn("--pr", calls[0]["args"])
        rows = {row["device"]: row for row in calls[0]["batch"]}
        self.assertEqual(set(rows), {"stable", "nightly"})
        self.assertFalse(rows["stable"]["nightly"])
        self.assertTrue(rows["nightly"]["nightly"])
        self.assertEqual(len(calls[0]["batch"]), 2)

    def test_all_devices_held_back_yields_empty_batch(self):
        self.entry("held", "held")
        self.write_json("cloud/master.json", {"devices": {"held": {"latest": "old"}}})
        self.write_json("cloud/held.json", {"versions": {"old": {"extensions": [{}]}, "new": {}}})
        result, calls = self.run_step("Update master manifest")
        self.assertEqual(result.returncode, 1)
        self.assertEqual([call["batch"] for call in calls], [[]])

    def test_no_entries_skips_publisher(self):
        for name in ("Update master manifest", "Update PR master manifest"):
            with self.subTest(name=name):
                result, calls = self.run_step(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, [])

    def test_malformed_entry_fails_before_publishing(self):
        (self.root / "manifest-entries/bad.json").write_text("bad JSON")
        for name in ("Update master manifest", "Update PR master manifest"):
            with self.subTest(name=name):
                result, calls = self.run_step(name)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
