import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("orin_producer", Path(__file__).with_name("test-orin-seed-producer.py"))
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)


class ProducerArchiveBindingTests(unittest.TestCase):
    def test_descriptor_binds_existing_bytes_without_changing_producer_file(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "finished.flashpack.tar.zst"
            payload = bytes(range(256)) * 4096
            archive.write_bytes(payload)
            archive.chmod(0o444)
            result = PRODUCER.descriptor(archive, "nightly-20261113T000000")
            self.assertEqual(result["sha256"], hashlib.sha256(payload).hexdigest())
            self.assertEqual(result["size_bytes"], len(payload))
            self.assertEqual(result["url"], archive.resolve().as_uri())
            self.assertEqual(result["device"], "jetson-orin-nano")
            self.assertEqual(result["storage"], "nvme")
            self.assertEqual(archive.read_bytes(), payload)
            self.assertEqual(archive.stat().st_mode & 0o777, 0o444)

    def test_rejects_empty_missing_or_unsafe_version_input(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "finished.flashpack.tar.zst"
            with self.assertRaises(ValueError):
                PRODUCER.descriptor(archive, "0.20.2")
            archive.touch()
            with self.assertRaises(ValueError):
                PRODUCER.descriptor(archive, "0.20.2")
            archive.write_bytes(b"archive")
            for version in ("../other", "", "two\nversions", "$(command)"):
                with self.assertRaises(ValueError):
                    PRODUCER.descriptor(archive, version)


if __name__ == "__main__":
    unittest.main()
