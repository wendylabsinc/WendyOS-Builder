"""Run the artifact packaging command against rootfs marker fixtures."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ArtifactManifestTests(unittest.TestCase):
    def pack_arguments(self, marker):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            rootfs = directory / 'rootfs'
            rootfs.mkdir()
            if marker:
                path = rootfs / 'var/lib/wendyos/update-bootloader'
                path.parent.mkdir(parents=True)
                path.touch()

            # Capture the real image-class invocation, without compressing a
            # multi-gigabyte image or depending on a Yocto native toolchain.
            tool = directory / 'wendyos-update'
            tool.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                            'open(os.environ["PACK_ARGS"], "w").write(json.dumps(sys.argv[1:]))\n')
            tool.chmod(0o755)
            source = (ROOT / 'classes/image_types_wendy.bbclass').read_text()
            body = source.split('IMAGE_CMD:wendy () {\n', 1)[1].split('\n}', 1)[0]
            values = {
                'WENDYOS_BOARD_ID': 'jetson-agx-thor',
                'WENDYOS_ROOTFS_SIZE_KB': '',
                'IMAGE_ROOTFS': str(rootfs),
                'IMGDEPLOYDIR': str(directory),
                'IMAGE_LINK_NAME': 'test-rootfs',
                'IMAGE_NAME': 'test-image',
                'WENDY_ARTIFACTIMG_FSTYPE': 'ext4',
                'WENDY_ARTIFACT_NAME': 'test-artifact',
                'WENDY_ARTIFACT_VERSION': '1.0.0',
                'WENDY_ARTIFACT_COMPRESSION': 'zstd',
            }
            body = re.sub(r'\$\{([A-Z_]+)\}', lambda match: values[match[1]], body)
            args_file = directory / 'pack-args.json'
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'], PACK_ARGS=str(args_file))
            subprocess.run(['sh', '-eu', '-c', body], check=True, env=env)
            return json.loads(args_file.read_text())

    def test_capsule_marker_is_reported(self):
        self.assertIn('--bootloader-update=true', self.pack_arguments(marker=True))

    def test_rootfs_only_image_is_reported(self):
        self.assertIn('--bootloader-update=false', self.pack_arguments(marker=False))


if __name__ == '__main__':
    unittest.main()
