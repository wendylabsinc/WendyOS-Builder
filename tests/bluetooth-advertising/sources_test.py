"""Reject changed network or cache input before running patch/compiler commands."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import run


class SourceIntegrityTests(unittest.TestCase):
    def test_exact_bytes_required(self):
        data = b"trusted source\n"
        with patch.dict(run.FILES, {"fixture": hashlib.sha256(data).hexdigest()}):
            run.verify_source("fixture", data)
            for changed in (data + b" ", b"", b"untrusted source\n"):
                with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                    run.verify_source("fixture", changed)

    def test_changed_cached_source_never_reaches_patch_or_compiler(self):
        with tempfile.TemporaryDirectory() as cache:
            first = Path(cache) / next(iter(run.FILES))
            first.parent.mkdir(parents=True)
            first.write_bytes(b"changed source")
            with patch("sys.argv", ["run.py", "--sources", cache]), patch.object(run.subprocess, "run") as command:
                with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                    run.main()
                command.assert_not_called()

    def test_changed_download_never_reaches_patch_or_compiler(self):
        with patch("sys.argv", ["run.py"]), patch.object(run.urllib.request, "urlopen") as fetch, patch.object(run.subprocess, "run") as command:
            fetch.return_value.read.return_value = b"changed source"
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                run.main()
            command.assert_not_called()
