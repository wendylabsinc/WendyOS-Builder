#!/usr/bin/env python3
"""Run the patched supplicant's module tests without touching host radios."""

import argparse
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def run(binary, log):
    # A short path avoids the Unix socket path-length limit.
    with tempfile.TemporaryDirectory(prefix="nan-test-", dir="/tmp") as tmp:
        control = str(Path(tmp) / "global")
        with log.open("w") as output:
            # No interface or D-Bus registration: this is a private test instance.
            process = subprocess.Popen(
                [str(binary), "-dd", "-g", control],
                stdout=output, stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.monotonic() + 10
                while not Path(control).exists():
                    if process.poll() is not None:
                        raise RuntimeError("supplicant exited before creating its socket")
                    if time.monotonic() >= deadline:
                        raise RuntimeError("timed out waiting for the control socket")
                    time.sleep(0.05)

                with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
                    client.bind(str(Path(tmp) / "client"))
                    client.connect(control)
                    client.settimeout(1)
                    client.send(b"MODULE_TESTS")
                    deadline = time.monotonic() + 120
                    while True:
                        if process.poll() is not None:
                            raise RuntimeError(
                                f"supplicant exited during module tests: {process.returncode}"
                            )
                        if time.monotonic() >= deadline:
                            raise RuntimeError("module tests timed out")
                        try:
                            reply = client.recv(4096).decode().strip()
                            break
                        except socket.timeout:
                            pass
                    if reply != "OK":
                        raise RuntimeError(f"MODULE_TESTS returned {reply!r}")
            finally:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

    if "NAN unselected NDC Request regression: PASS" not in log.read_text():
        raise RuntimeError("Android NDC regression did not run; check patches and build flags")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="test-enabled wpa_supplicant binary")
    parser.add_argument("--log", type=Path, default=Path("nan-module-tests.log"))
    args = parser.parse_args()
    try:
        run(args.binary.resolve(), args.log)
    except (OSError, RuntimeError) as error:
        parser.exit(1, f"FAIL: {error}; log: {args.log}\n")
    print(f"PASS: Android NDC regression and full module suite; log: {args.log}")


if __name__ == "__main__":
    main()
