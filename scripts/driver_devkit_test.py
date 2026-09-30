"""Run the shipped CI devkit selector with isolated curl fixtures."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def manifest(version, kernel):
    return {"versions": {version: {"devkit": {"kernel_version": kernel}}}}


class DevkitTests(unittest.TestCase):
    def select(self, pr=None, public=None, prefix="pr/262/", want="pr-262",
               os_devices="", entries=(), device="jetson-agx-thor", expected_status=0):
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
            built = Path(tmp) / "entries"
            built.mkdir()
            for i, entry in enumerate(entries):
                (built / f"{i}.json").write_text(json.dumps(entry))
            env.update(OS_DEVICES=os_devices, BUILT_ENTRIES=str(built),
                       DEVICE_INVENTORY=str(ROOT / ".github/device-artifacts.json"),
                       GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2",
                       GITHUB_STEP_SUMMARY=str(Path(tmp) / "summary"))
            result = subprocess.run(["bash", str(ROOT / "scripts/select-driver-devkit.sh"), device], env=env,
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, expected_status, result.stderr)
            self.last_stderr = result.stderr
            return (json.loads(result.stdout) if result.stdout else None), (log.read_text().splitlines() if log.exists() else [])

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
        selected, urls = self.select(public={"versions": {}}, prefix="", expected_status=1)
        self.assertIsNone(selected)
        self.assertEqual(len(urls), 1)

    def test_no_devkit_skips_device(self):
        selected, urls = self.select(pr={"versions": {}}, public={"versions": {}}, expected_status=1)
        self.assertIsNone(selected)
        self.assertEqual(len(urls), 2)

    def test_requested_version_wins_over_newest(self):
        public = manifest("0.19.1", "6.8")
        public["versions"].update(manifest("0.19.2", "6.9")["versions"])
        selected, _ = self.select(public=public, prefix="", want="0.19.1")
        self.assertEqual(selected["version"], "0.19.1")

    def entry(self, **overrides):
        entry = dict(device="jetson-agx-thor", version="pr-262", storage="nvme",
                     nightly=True, build_run_id="123", build_run_attempt="2",
                     devkit=dict(kernel_version="6.9", path="pr/262/devkit", sha256="abc"))
        entry.update(overrides)
        return entry

    def test_fallback_logs_public_source(self):
        self.select(public=manifest("0.19.1", "6.8"))
        self.assertIn("::warning::", self.last_stderr)
        self.assertIn("PUBLIC devkit", self.last_stderr)
        self.assertIn("source=https://fixture.invalid/manifests/jetson-agx-thor.json", self.last_stderr)

    def test_os_build_uses_current_artifact_without_network(self):
        selected, urls = self.select(os_devices="jetson-agx-thor", entries=[self.entry()])
        self.assertEqual(urls, [])
        self.assertEqual(selected["devkit"]["kernel_version"], "6.9")
        self.assertEqual(selected["source"], "current OS build artifact")

    def test_failed_job_rerun_uses_successful_os_artifact_from_prior_attempt(self):
        selected, urls = self.select(os_devices="jetson-agx-thor",
                                     entries=[self.entry(build_run_attempt="1")])
        self.assertEqual(urls, [])
        self.assertEqual(selected["devkit"]["kernel_version"], "6.9")

    def test_os_build_refuses_missing_or_stale_artifacts(self):
        for entries in [[], [self.entry(build_run_id="old")], [self.entry(version="pr-261")],
                        [self.entry(devkit=None)]]:
            with self.subTest(entries=entries):
                _, urls = self.select(os_devices="jetson-agx-thor", entries=entries,
                                      public=manifest("0.19.1", "6.8"), expected_status=2)
                self.assertEqual(urls, [])
                self.assertIn("refusing", self.last_stderr)

    def test_os_build_alias_uses_emmc_devkit(self):
        entries = [self.entry(device="jetson-agx-orin", storage="nvme"),
                   self.entry(device="jetson-agx-orin", storage="emmc", aliases=["jetson-agx-orin-emmc"],
                              devkit=dict(kernel_version="emmc-kernel"))]
        selected, _ = self.select(os_devices="jetson-agx-orin", entries=entries, device="jetson-agx-orin-emmc")
        self.assertEqual(selected["devkit"]["kernel_version"], "emmc-kernel")

    def test_non_opted_in_or_unbuilt_device_is_skipped(self):
        for device in ["jetson-agx-orin", "vm-arm64"]:
            _, urls = self.select(os_devices="jetson-agx-thor vm-arm64", device=device, expected_status=1)
            self.assertEqual(urls, [])

    def test_explicit_version_does_not_select_another_version(self):
        selected, _ = self.select(public=manifest("0.19.1", "6.8"), prefix="", want="0.19.2", expected_status=1)
        self.assertIsNone(selected)


if __name__ == "__main__":
    unittest.main()
