#!/usr/bin/env python3
"""Compile actual patched kernel lifecycle functions and exercise expiry retirement."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
PIN = "95b85bebbedcaedfa7ca79116ed38b7376fba412"
FILES = {
    "net/bluetooth/hci_sync.c": "2612da3e70d44cd1db5f6bf43ea861d3fba4e167c0436be7fb5941f339409362",
    "net/bluetooth/hci_core.c": "6d0ca82f4ac6f5db31322ba2be3a540f006498db400f225f1f26aa5acd9d8900",
    "net/bluetooth/mgmt.c": "d9ccb164f68dbe4621398438226a4d2b097020dbf9e0450b39226ace25eab387",
    "include/net/bluetooth/hci_core.h": "a5eb5072841f8a619bf787c64b52bc213dcd763010209560938fe421283ee248",
}


def verify_source(name, source):
    if hashlib.sha256(source).hexdigest() != FILES[name]:
        raise ValueError(f"SHA-256 mismatch for {name} at {PIN}")


def function(source, name):
    m = re.search(r"(?:static )?(?:int|void|bool|u8|unsigned long) " + name + r"\([^;]*?\)\s*\{", source)
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
            verify_source(name, source)
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
        # Deliberately provide no command-work queue or mutex in this harness:
        # the actual expiry predicate must use its device-lock-owned state only.
        expiry = Path(__file__).with_name("expiry.c").read_text()
        for name in re.findall(r"/\* BODY: (\w+) \*/", expiry):
            file = "mgmt" if name == "mgmt_cancel_adv_timeout" else "hci_sync"
            body = function((work / ("net/bluetooth/" + file + ".c")).read_text(), "cancel_adv_timeout" if name == "mgmt_cancel_adv_timeout" else name)
            if name == "mgmt_cancel_adv_timeout":
                body = body.replace("cancel_adv_timeout", name)
            expiry = expiry.replace("/* BODY: " + name + " */", body)
        c = work / "expiry.c"
        c.write_text(expiry)
        binary = c.with_suffix("")
        subprocess.run([os.environ.get("CC", "cc"), "-std=gnu11", "-Wall", "-Wextra", "-Werror", str(c), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
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
