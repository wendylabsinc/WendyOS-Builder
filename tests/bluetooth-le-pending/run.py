#!/usr/bin/env python3
"""Apply the shared backport to pinned vendor files and run their actual callbacks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
SOURCES = {
    "pi": "https://raw.githubusercontent.com/raspberrypi/linux/95b85bebbedcaedfa7ca79116ed38b7376fba412/net/bluetooth/hci_sync.c",
    "jetson": "https://gitlab.com/nvidia/nv-tegra/3rdparty/canonical/linux-noble/-/raw/78272943bba3a47e633b28963b0cda60de503500/net/bluetooth/hci_sync.c",
    "qcom": "https://raw.githubusercontent.com/qualcomm-linux/kernel/1a0586064ee1fbcefe49b6382ee17a236c590879/net/bluetooth/hci_sync.c",
}

def callback(source):
    start = source.index("static void create_le_conn_complete(")
    end = source.index("\n}\n", start) + 2
    return source[start:end]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, help="directory containing pi.c, jetson.c and qcom.c; otherwise fetch pinned sources")
    args = parser.parse_args()
    patch = ROOT / "recipes-kernel/linux/bluetooth-le-pending/0001-bluetooth-clean-up-rejected-pending-le-connection.patch"
    harness = Path(__file__).with_name("harness.c").read_text()
    # qcom-next already carries the fix (upstream 7e1e4047200f), so the Qualcomm
    # append, which Arduino layers too, must not apply the backport again.
    qcom = (ROOT / "meta-qcom-extensions/recipes-kernel/linux/linux-qcom-next_%.bbappend").read_text()
    assert "bluetooth-le-pending" not in qcom
    assert "BLUETOOTH_LE_PENDING_PATCH" not in qcom
    arduino = (ROOT / "conf/template/boards/arduino-uno-q/bblayers.conf").read_text()
    assert "include/bblayers/qcom.inc" in arduino
    with tempfile.TemporaryDirectory(prefix="ble-pending-") as temp:
        work = Path(temp)
        target = work / "net/bluetooth/hci_sync.c"
        target.parent.mkdir(parents=True)
        for name, url in SOURCES.items():
            source = (args.sources / (name + ".c")).read_text() if args.sources else urllib.request.urlopen(url, timeout=120).read().decode()
            target.write_text(source)
            if name == "qcom":
                # Fixed upstream: the shipped callback itself must pass.
                cases = [("upstream", source, 0)]
            else:
                subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(patch)], cwd=work, check=True)
                cases = [("original", source, 86), ("patched", target.read_text(), 0)]
            for label, code, expected in cases:
                body = callback(code)
                test = harness.replace("/* CALLBACK */", body)
                c = work / (name + "-" + label + ".c")
                binary = c.with_suffix("")
                c.write_text(test)
                subprocess.run([os.environ.get("CC", "cc"), "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-DEXPECT_PUTS=" + str(int(name == "qcom")), str(c), "-o", str(binary)], check=True)
                result = subprocess.run([str(binary)], text=True, capture_output=True)
                assert result.returncode == expected, (name, label, result.stdout, result.stderr)
                print(name, label, "expected", expected, "actual", result.returncode, flush=True)
                print(result.stdout, end="")
            print(json.dumps({"vendor": name, "source": url, "sha256": hashlib.sha256(source.encode()).hexdigest()}))

if __name__ == "__main__":
    main()
