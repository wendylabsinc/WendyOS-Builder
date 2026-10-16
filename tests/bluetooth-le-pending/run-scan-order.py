#!/usr/bin/env python3
"""Exercise actual Jetson synchronous create, scan-disable and completion code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
PIN = "78272943bba3a47e633b28963b0cda60de503500"
BASE = f"https://gitlab.com/nvidia/nv-tegra/3rdparty/canonical/linux-noble/-/raw/{PIN}/net/bluetooth/"
HASHES = {"hci_sync.c": "d617d6460ccfe53954759e990d00bd506ee5dbf194404827bf66534349afd668",
          "hci_event.c": "4307e42dc006dd0555b801202191df6e792373f3163b75eba4767e06baadca24"}


def function(source, name):
    match = re.search(r"^static (?:int|void) " + re.escape(name) + r"\([^;{]*\)\n\{", source, re.M)
    if not match:
        raise ValueError("missing function: " + name)
    end = source.index("\n}\n", match.start()) + 2
    return source[match.start():end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, help="directory with pinned hci_sync.c and hci_event.c")
    args = parser.parse_args()
    sources = {}
    for name, digest in HASHES.items():
        raw = (args.sources / name).read_bytes() if args.sources else urllib.request.urlopen(BASE + name, timeout=120).read()
        if hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError("pinned source mismatch: " + name)
        sources[name] = raw.decode()
    patch = ROOT / "meta-tegra-extensions-jp7/recipes-kernel/linux/linux-noble-nvidia-tegra/0007-bluetooth-mark-scan-interrupted-before-disable.patch"
    harness = Path(__file__).with_name("scan-order.c").read_text()
    with tempfile.TemporaryDirectory(prefix="ble-scan-order-") as folder:
        work = Path(folder)
        target = work / "net/bluetooth/hci_sync.c"
        target.parent.mkdir(parents=True)
        target.write_text(sources["hci_sync.c"])
        subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(patch)], cwd=work, check=True)
        for label, source, expected in [("original", sources["hci_sync.c"], 86), ("patched", target.read_text(), 0)]:
            code = harness.replace("/* EVENT_HANDLER */", function(sources["hci_event.c"], "le_set_scan_enable_complete"))
            code = code.replace("/* SCAN_DISABLE */", function(source, "hci_scan_disable_sync"))
            code = code.replace("/* CREATE_CONN */", function(source, "hci_le_create_conn_sync"))
            c = work / (label + ".c")
            binary = c.with_suffix("")
            c.write_text(code)
            subprocess.run([os.environ.get("CC", "cc"), "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", str(c), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], text=True, capture_output=True)
            print(label, result.returncode, result.stdout, flush=True)
            if result.returncode != expected:
                raise AssertionError((label, expected, result.returncode, result.stdout, result.stderr))
    print(json.dumps({"source_revision": PIN, "source_sha256": HASHES, "cases": 12, "patched": "pass", "original": "expected failure"}))


if __name__ == "__main__":
    main()
