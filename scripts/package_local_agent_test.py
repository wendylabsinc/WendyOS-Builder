"""Exercise local-agent packaging and provenance without compiling the full agent."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('package_local_agent', ROOT / 'tools/mesh/package-local-agent.py')
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class LocalAgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.builder = self.root / 'builder'
        self.source.mkdir()
        self.builder.mkdir()
        (self.source / 'main.go').write_text('package main\n')
        for path in ['conf/layer.conf', 'tools/mesh/package-local-agent.py'] + [
            f'recipes-core/wendyos-agent/files/{name}' for name in PACKAGE.SERVICE_FILES
        ]:
            target = self.builder / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / path).read_bytes())
        for repo in (self.source, self.builder):
            self.git(repo, 'init', '-q')
            self.git(repo, 'add', '.')
            self.git(repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                     'commit', '-qm', 'fixture')
        self.go = self.root / 'go'
        self.go.write_text(f'#!{sys.executable}\n' + '''import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['GO_CALL_LOG'], 'a') as f:
    f.write(json.dumps({'args': args, 'cwd': os.getcwd(), 'gowork': os.environ.get('GOWORK'),
                        'goflags': os.environ.get('GOFLAGS')}) + '\\n')
if args[0] == 'build':
    data = bytearray(64)
    data[:4] = b'\\x7fELF'
    data[18:20] = (183).to_bytes(2, 'little')
    pathlib.Path(args[args.index('-o') + 1]).write_bytes(data)
    if os.environ.get('MUTATE_INPUT'):
        pathlib.Path(os.environ['MUTATE_INPUT']).write_text('uncommitted change')
elif args[:2] == ['version', '-m']:
    print(args[2] + ': go1.27.0')
    print('\\tbuild\\tGOARCH=arm64')
else:
    print('go version go1.26.4 linux/amd64')
''')
        self.go.chmod(0o755)
        self.log = self.root / 'go-calls.jsonl'
        env = patch.dict(os.environ, GO_CALL_LOG=str(self.log),
                         GOWORK='/unrecorded/go.work', GOFLAGS='-tags=unrecorded')
        env.start()
        self.addCleanup(env.stop)

    def git(self, repo, *args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()

    def package(self, output='output'):
        return PACKAGE.package_agent(self.source, self.root / output, str(self.go),
                                     '2026.10.09-test', self.builder)

    def test_records_binary_compiler_and_committed_builder_inputs(self):
        manifest = self.package()
        self.assertEqual(manifest['go_version'], 'go1.27.0')
        self.assertIn('GOARCH=arm64', manifest['go_build_info'])
        self.assertEqual(manifest['builder_commit'], self.git(self.builder, 'rev-parse', 'HEAD'))
        for path, digest in manifest['builder_files_sha256'].items():
            self.assertEqual(digest, hashlib.sha256((self.builder / path).read_bytes()).hexdigest())
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(calls[1]['args'][:2], ['version', '-m'])
        self.assertEqual(calls[0]['cwd'], str(self.source.resolve()))
        self.assertEqual(calls[0]['gowork'], 'off')
        self.assertEqual(calls[0]['goflags'], '')
        self.assertIn('-mod=readonly', calls[0]['args'])

    def test_deterministic_archive_and_generated_layer(self):
        first, second = self.package('one'), self.package('two')
        self.assertEqual(first['archive_sha256'], second['archive_sha256'])
        files = self.root / 'one/layer/recipes-core/wendyos-agent/files'
        archive = next(files.glob('*.tar.gz'))
        with tarfile.open(archive) as tar:
            self.assertEqual(tar.getnames(), ['wendy-agent-linux-arm64/wendy-agent'])
            entry = tar.getmembers()[0]
            self.assertEqual((entry.mode, entry.uid, entry.gid, entry.mtime), (0o755, 0, 0, 0))
            self.assertEqual(tar.extractfile(entry).read(), (self.root / 'one/wendy-agent').read_bytes())
        append = (files.parent / 'wendyos-agent_1.0.bbappend').read_text()
        self.assertIn(first['archive_sha256'], append)
        self.assertIn('ln -sf /dev/null', append)
        self.assertIn('SYSTEMD_SERVICE:${PN} = "wendyos-agent.service"', append)
        self.assertFalse(first['hardware_acceptance'])
        self.assertEqual(first['bitbake_validation'], 'PENDING')

    def test_rejects_dirty_builder_before_building(self):
        (self.builder / 'recipes-core/wendyos-agent/files/wendyos-agent.service').write_text('local edit')
        with self.assertRaisesRegex(ValueError, 'committed and clean'):
            self.package()
        self.assertFalse(self.log.exists())
        self.assertFalse((self.root / 'output').exists())

    def test_copies_recorded_builder_revision_if_checkout_changes_during_build(self):
        path = 'recipes-core/wendyos-agent/files/wendyos-agent.service'
        expected = (self.builder / path).read_bytes()
        with patch.dict(os.environ, MUTATE_INPUT=str(self.builder / path)):
            manifest = self.package()
        copied = self.root / 'output/layer' / path
        self.assertEqual(copied.read_bytes(), expected)
        self.assertEqual(manifest['builder_files_sha256'][path], hashlib.sha256(expected).hexdigest())

    def test_rejects_source_changes_during_build(self):
        with patch.dict(os.environ, MUTATE_INPUT=str(self.source / 'main.go')):
            with self.assertRaisesRegex(ValueError, 'committed and clean'):
                self.package()
        self.assertFalse((self.root / 'output/BUILD-PROVENANCE.json').exists())

    def test_checks_are_not_disabled_by_python_optimization(self):
        (self.source / 'main.go').write_text('dirty source')
        result = subprocess.run([
            sys.executable, '-O', str(self.builder / 'tools/mesh/package-local-agent.py'),
            '--source', str(self.source), '--output', str(self.root / 'output'),
            '--go', str(self.go), '--version', 'test',
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('committed and clean', result.stderr)
        self.assertFalse(self.log.exists())

    def test_rejects_output_inside_a_checkout(self):
        for repo in (self.source, self.builder):
            with self.subTest(repo=repo), self.assertRaisesRegex(ValueError, 'outside'):
                PACKAGE.package_agent(self.source, repo / 'output', str(self.go), 'test', self.builder)

    def test_rejects_unsafe_version_and_existing_output(self):
        with self.assertRaisesRegex(ValueError, 'unsafe version'):
            PACKAGE.package_agent(self.source, self.root / 'output', str(self.go), '../bad', self.builder)
        (self.root / 'output').mkdir()
        with self.assertRaisesRegex(ValueError, 'fresh output'):
            self.package()


if __name__ == '__main__':
    unittest.main()
