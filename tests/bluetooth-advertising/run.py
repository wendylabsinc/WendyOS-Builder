#!/usr/bin/env python3
"""Compile actual patched kernel lifecycle functions and exercise expiry retirement."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
PIN = "95b85bebbedcaedfa7ca79116ed38b7376fba412"
FILES = ["net/bluetooth/hci_sync.c", "net/bluetooth/hci_core.c", "net/bluetooth/mgmt.c", "include/net/bluetooth/hci_core.h"]

def function(source, name):
    m = re.search(r"(?:static )?(?:int|void|bool|u8) " + name + r"\([^;]*?\)\s*\{", source)
    assert m, name
    p, depth = m.end(), 1
    while depth:
        depth += (source[p] == "{") - (source[p] == "}")
        p += 1
    return source[m.start():p]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, help="unpatched pinned Raspberry Pi source tree; otherwise fetch")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ble-advertising-") as temp:
        work = Path(temp)
        for name in FILES:
            target = work / name
            target.parent.mkdir(parents=True, exist_ok=True)
            source = (args.sources / name).read_bytes() if args.sources else urllib.request.urlopen("https://raw.githubusercontent.com/raspberrypi/linux/" + PIN + "/" + name, timeout=120).read()
            target.write_bytes(source)
        patches = [ROOT / "recipes-kernel/linux/bluetooth-le-pending/0001-bluetooth-clean-up-rejected-pending-le-connection.patch", ROOT / "meta-rpi-extensions/recipes-kernel/linux/linux-raspberrypi/0004-bluetooth-legacy-active-scan-retain-expiry.patch"]
        for patch in patches:
            subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(patch)], cwd=work, check=True)
        code = Path(__file__).with_name("lifecycle.c").read_text()
        for name in re.findall(r"/\* BODY: (\w+) \*/", code):
            file = "mgmt" if name == "mgmt_cancel_adv_timeout" else "hci_core" if name in ["hci_remove_adv_instance", "hci_adv_instances_clear"] else "hci_sync"
            body = function((work / ("net/bluetooth/" + file + ".c")).read_text(), "cancel_adv_timeout" if name == "mgmt_cancel_adv_timeout" else name)
            if name == "mgmt_cancel_adv_timeout":
                body = body.replace("cancel_adv_timeout", name)
            code = code.replace("/* BODY: " + name + " */", body)
        # Mutation check: the prior cleanup only retired expiry when still selected.
        # Removing the new independent clear must reproduce the scheduling failure.
        independent = "\n\tif (hdev->expired_adv_instance == instance)\n\t\thdev->expired_adv_instance = 0;"
        assert code.count(independent) == 3
        for label, test, expected in [("fixed", code, 0), ("prior-cleanup", code.replace(independent, ""), 86)]:
            c = work / (label + ".c")
            binary = c.with_suffix("")
            c.write_text(test)
            subprocess.run([os.environ.get("CC", "cc"), "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-Wno-unused-parameter", "-Wno-unused-but-set-variable", str(c), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], text=True, capture_output=True)
            print(label, result.stdout.strip(), flush=True)
            assert result.returncode == expected, result.stdout + result.stderr

if __name__ == "__main__":
    main()
