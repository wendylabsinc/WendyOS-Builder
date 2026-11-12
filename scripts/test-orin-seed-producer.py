#!/usr/bin/env python3
"""Gate the existing Nano/NVMe producer archive with the pinned CLI rehearsal."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

# Same upstream bytes pinned by WendyOS/.github/scripts/build-linux-release-cli.sh.
LIBUSB_VERSION = "1.0.29"
LIBUSB_SHA256 = "5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def descriptor(archive, version):
    if not re.fullmatch(r"[a-zA-Z0-9._-]+", version):
        raise ValueError("invalid producer version")
    if not archive.is_file() or archive.stat().st_size == 0:
        raise ValueError("producer archive is missing or empty")
    return {"device": "jetson-orin-nano", "storage": "nvme", "version": version,
            # This is a producer artifact, not a claim that it was published.
            # Any unexpected download fallback fails closed on the file URL.
            "url": archive.resolve().as_uri(), "sha256": digest(archive),
            "size_bytes": archive.stat().st_size}


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli-root", type=Path, required=True)
    parser.add_argument("--cli-commit", required=True)
    parser.add_argument("--archive-dir", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--work-parent", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "linux" or not re.fullmatch("[0-9a-f]{40}", args.cli_commit):
        parser.error("requires Linux and an exact reviewed CLI commit")
    cli = args.cli_root.resolve(strict=True)
    actual_commit = subprocess.check_output(["git", "-C", str(cli), "rev-parse", "HEAD"], text=True, timeout=10).strip()
    if actual_commit != args.cli_commit:
        parser.error("companion checkout is not the reviewed CLI commit")
    archives = list(args.archive_dir.glob("*.flashpack.tar.zst"))
    if len(archives) != 1:
        parser.error("expected exactly one existing Nano/NVMe producer archive")
    archive = archives[0].resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=False)
    output = args.output.resolve()
    evidence = {"passed": False, "cli_commit": actual_commit, "version": args.version,
                "producer_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True, timeout=10).strip(),
                "archive": str(archive), "cleanup_errors": []}
    work_parent = args.work_parent.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix="wendy-orin-native-deps-", dir=work_parent))
    guardian = load_module("orin_producer_guardian", cli / ".github/scripts/run-owned-media-test.py")
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    original_env = os.environ.copy()
    original_argv = sys.argv[:]

    def interrupted(signum, frame):
        raise InterruptedError(f"interrupted by signal {signum}")

    def run(name, command, timeout=600):
        print(f"Orin producer: {name} (deadline {timeout}s)", flush=True)
        with (output / (name + ".log")).open("w") as log:
            code = guardian.run(command, timeout, cwd=work, stdout=log)
        if code != 0:
            raise RuntimeError(f"{name} failed with {code}; see {output / (name + '.log')}")

    try:
        for sig in previous:
            signal.signal(sig, interrupted)
        if shutil.disk_usage(work).free < 40 * 1024 ** 3:
            raise RuntimeError("producer rehearsal requires at least 40 GiB free before preparing dependencies")
        # Existing libsdl1.2-dev supplies ALSA development files on the producer
        # image. Fail explicitly if that image contract changes; no host install.
        subprocess.run(["pkg-config", "--exists", "alsa"], check=True, timeout=10)
        if subprocess.run(["pkg-config", "--exists", "libusb-1.0"], timeout=10).returncode != 0:
            prefix = work / "prefix"
            bootstrap = work / "libusb.sh"
            bootstrap.write_text('''#!/usr/bin/env bash
set -euo pipefail
curl --fail --location --retry 2 --connect-timeout 20 --max-time 180 \\
  --output libusb.tar.bz2 "https://github.com/libusb/libusb/releases/download/v${LIBUSB_VERSION}/libusb-${LIBUSB_VERSION}.tar.bz2"
printf '%s  libusb.tar.bz2\\n' "$LIBUSB_SHA256" | sha256sum -c -
tar -xjf libusb.tar.bz2
cd "libusb-$LIBUSB_VERSION"
CFLAGS=-fPIC ./configure --disable-udev --disable-shared --enable-static --prefix="$LIBUSB_PREFIX"
make -j2
make install
''')
            os.environ.update(LIBUSB_VERSION=LIBUSB_VERSION, LIBUSB_SHA256=LIBUSB_SHA256, LIBUSB_PREFIX=str(prefix))
            run("build-private-libusb", ["bash", str(bootstrap)])
            os.environ["PKG_CONFIG_PATH"] = str(prefix / "lib/pkgconfig") + (":" + original_env["PKG_CONFIG_PATH"] if original_env.get("PKG_CONFIG_PATH") else "")
            evidence["libusb"] = {"source_version": LIBUSB_VERSION, "source_sha256": LIBUSB_SHA256,
                                  "static_library_sha256": digest(prefix / "lib/libusb-1.0.a")}
        else:
            evidence["libusb"] = {"source": "existing producer development package"}
        run("native-link-flags", ["bash", "-c", "set -euo pipefail; pkg-config --modversion libusb-1.0 alsa; pkg-config --cflags --libs libusb-1.0 alsa"], 10)
        (work / "libusb-smoke.c").write_text(
            '#include <stdio.h>\n#include <libusb.h>\n'
            'int main(void) { const struct libusb_version *v = libusb_get_version(); '
            'printf("libusb runtime %u.%u.%u\\n", v->major, v->minor, v->micro); return v->major != 1; }\n')
        run("native-libusb-smoke", ["bash", "-c",
            'set -euo pipefail; gcc libusb-smoke.c $(pkg-config --cflags --libs libusb-1.0) -o libusb-smoke; '
            './libusb-smoke; ldd libusb-smoke > libusb-smoke.ldd; cat libusb-smoke.ldd; ' +
            ('! grep -q "libusb.*\\.so" libusb-smoke.ldd' if "static_library_sha256" in evidence["libusb"] else "true")], 30)
        # Scope toolchain selection to this process and its children. The later
        # publisher still sees the workflow's original Go1.25 PATH/environment.
        os.environ.update(GOTOOLCHAIN="go1.27.4", CGO_ENABLED="1", GOCACHE=str(work / "go-build"))
        # Descriptor hashing is performed by a bounded owned subprocess too.
        run("pin-producer-archive", [sys.executable, "-c",
            "import importlib.util,json,sys; from pathlib import Path; "
            "s=importlib.util.spec_from_file_location('producer',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m); "
            "Path(sys.argv[4]).write_text(json.dumps(m.descriptor(Path(sys.argv[2]),sys.argv[3]),indent=2)+'\\n')",
            str(Path(__file__).resolve()), str(archive), args.version, str(output / "fixture.json")])
        driver = load_module("orin_producer_rehearsal", cli / ".github/scripts/test-orin-seed-rehearsal.py")
        sys.argv = [str(cli / ".github/scripts/test-orin-seed-rehearsal.py"), "--archive", str(archive),
                    "--fixture", str(output / "fixture.json"), "--work-parent", str(work_parent),
                    "--output", str(output / "rehearsal")]
        # Direct call preserves the guardian's signal ownership; no outer
        # timeout can kill a driver before it drains an inner process group.
        result = driver.main()
        if result != 0:
            raise RuntimeError("full Orin rehearsal failed; see rehearsal/evidence.json")
        evidence["passed"] = True
    except Exception as error:
        evidence["error"] = str(error)
        print(error, file=sys.stderr)
    finally:
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        try:
            shutil.rmtree(work)
        except Exception as error:
            evidence["cleanup_errors"].append(str(error))
            evidence["passed"] = False
        try:
            (output / "producer.json").write_text(json.dumps(evidence, indent=2) + "\n")
        finally:
            os.environ.clear()
            os.environ.update(original_env)
            sys.argv = original_argv
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    return 0 if evidence["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
