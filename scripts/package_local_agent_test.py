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
        (self.source / '.gitignore').write_text('ignored.go\n')
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
mutated = os.environ.get('TRANSIENT_SOURCE_CHANGE') if args[0] == 'build' else None
if mutated:
    original = pathlib.Path(mutated).read_bytes()
    pathlib.Path(mutated).write_text('uncommitted source during build')
with open(os.environ['GO_CALL_LOG'], 'a') as f:
    f.write(json.dumps({'args': args, 'cwd': os.getcwd(), 'gowork': os.environ.get('GOWORK'),
                        'goflags': os.environ.get('GOFLAGS'),
                        'sources': {str(p): p.read_text() for p in pathlib.Path('.').glob('*.go')}}) + '\\n')
if mutated:
    pathlib.Path(mutated).write_bytes(original)
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

    def git(self, repo, *args, input=None):
        return subprocess.check_output(['git', '-C', str(repo), *args], input=input, text=True).strip()

    def package(self, output='output'):
        return PACKAGE.package_agent(self.source, self.root / output, str(self.go),
                                     '2026.10.09-test', self.builder)

    def test_records_binary_compiler_and_committed_builder_inputs(self):
        manifest = self.package()
        self.assertEqual(manifest['go_version'], 'go1.27.0')
        self.assertIn('GOARCH=arm64', manifest['go_build_info'])
        self.assertEqual(manifest['go_launcher_path'], str(self.go.resolve()))
        self.assertEqual(manifest['go_launcher_sha256'], hashlib.sha256(self.go.read_bytes()).hexdigest())
        self.assertEqual(manifest['builder_commit'], self.git(self.builder, 'rev-parse', 'HEAD'))
        for path, digest in manifest['builder_files_sha256'].items():
            self.assertEqual(digest, hashlib.sha256((self.builder / path).read_bytes()).hexdigest())
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(calls[1]['args'][:2], ['version', '-m'])
        self.assertNotEqual(calls[0]['cwd'], str(self.source.resolve()))
        self.assertEqual(calls[0]['cwd'], calls[1]['cwd'])
        self.assertEqual(calls[0]['sources'], {'main.go': 'package main\n'})
        self.assertFalse(Path(calls[0]['cwd']).exists())
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

    def test_excludes_ignored_go_sources_from_build(self):
        (self.source / 'ignored.go').write_text('this must never reach the compiler\n')
        self.assertEqual(self.git(self.source, 'status', '--porcelain'), '')
        manifest = self.package()
        call = json.loads(self.log.read_text().splitlines()[0])
        self.assertEqual(call['sources'], {'main.go': 'package main\n'})
        self.assertEqual(manifest['source_commit'], self.git(self.source, 'rev-parse', 'HEAD'))

    def test_original_source_edits_cannot_influence_compilation(self):
        with patch.dict(os.environ, TRANSIENT_SOURCE_CHANGE=str(self.source / 'main.go')):
            self.package()
        call = json.loads(self.log.read_text().splitlines()[0])
        self.assertEqual(call['sources'], {'main.go': 'package main\n'})

    def test_export_attributes_cannot_omit_or_rewrite_committed_sources(self):
        original = 'package main\n// $Format:%H$\n'
        (self.source / 'main.go').write_text(original)
        (self.source / 'optional.go').write_text('package main\nfunc init() {}\n')
        self.git(self.source, 'add', '.')
        self.git(self.source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'export fixture')
        attributes = 'optional.go export-ignore\nmain.go export-subst\n'
        for location in ('repository', 'global', 'committed'):
            with self.subTest(location=location):
                path = {'repository': self.source / '.git/info/attributes',
                        'global': self.root / 'global-attributes',
                        'committed': self.source / '.gitattributes'}[location]
                path.write_text(attributes)
                config = self.root / 'global-gitconfig'
                config.write_text('[core]\n\tattributesFile = ' + str(path) + '\n'
                                  if location == 'global' else '')
                if location == 'committed':
                    self.git(self.source, 'add', '.gitattributes')
                    self.git(self.source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                             'commit', '-qm', 'committed export attributes')
                with patch.dict(os.environ, GIT_CONFIG_GLOBAL=str(config)):
                    self.package(location)
                call = json.loads(self.log.read_text().splitlines()[-2])
                self.assertEqual(call['sources'], {'main.go': original,
                                 'optional.go': 'package main\nfunc init() {}\n'})
                if location != 'committed':
                    path.unlink()

    def test_raw_export_preserves_file_modes_and_symlinks(self):
        executable = self.source / 'tool'
        executable.write_bytes(b'#!/bin/sh\n')
        executable.chmod(0o755)
        (self.source / 'link').symlink_to('main.go')
        self.git(self.source, 'add', '.')
        self.git(self.source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'tree modes')
        target = self.root / 'export'
        target.mkdir()
        PACKAGE.export_revision(self.source, self.git(self.source, 'rev-parse', 'HEAD'),
                                target, self.root / 'objects')
        self.assertEqual((target / 'tool').stat().st_mode & 0o777, 0o755)
        self.assertEqual((target / 'main.go').stat().st_mode & 0o777, 0o644)
        self.assertTrue((target / 'link').is_symlink())
        self.assertEqual(os.readlink(target / 'link'), 'main.go')

    def test_replacement_refs_cannot_change_source_or_builder_bytes(self):
        commit, tree = PACKAGE.clean_revision(self.source)
        service = 'recipes-core/wendyos-agent/files/wendyos-agent.service'
        original_service = (self.builder / service).read_bytes()
        for repo, path, replacement in [(self.source, 'main.go', 'package replaced\n'),
                                         (self.builder, service, 'replaced service\n')]:
            original = self.git(repo, 'rev-parse', 'HEAD:' + path)
            substitute = self.git(repo, 'hash-object', '-w', '--stdin', input=replacement)
            self.git(repo, 'replace', original, substitute)
        # The caller cannot re-enable replacements through its environment.
        with patch.dict(os.environ, GIT_NO_REPLACE_OBJECTS='0'):
            manifest = self.package()
        call = json.loads(self.log.read_text().splitlines()[0])
        self.assertEqual(call['sources'], {'main.go': 'package main\n'})
        self.assertEqual((manifest['source_commit'], manifest['source_tree']), (commit, tree))
        self.assertEqual((self.root / 'output/layer' / service).read_bytes(), original_service)

    def test_replacement_tree_cannot_change_recorded_tree(self):
        commit, tree = PACKAGE.clean_revision(self.source)
        empty = self.git(self.source, 'mktree', input='')
        self.git(self.source, 'replace', tree, empty)
        self.assertEqual(PACKAGE.clean_revision(self.source), (commit, tree))
        self.package()
        call = json.loads(self.log.read_text().splitlines()[0])
        self.assertEqual(call['sources'], {'main.go': 'package main\n'})

    def test_case_colliding_symlink_cannot_write_outside_export(self):
        outside = self.root / 'outside'
        outside.mkdir()
        link = self.git(self.source, 'hash-object', '-w', '--stdin', input='../outside')
        blob = self.git(self.source, 'hash-object', '-w', '--stdin', input='escaped\n')
        subtree = self.git(self.source, 'mktree', input=f'100644 blob {blob}\tpayload\n')
        tree = self.git(self.source, 'mktree',
                        input=f'120000 blob {link}\tA\n040000 tree {subtree}\ta\n')
        target = self.root / 'export'
        target.mkdir()
        with self.assertRaisesRegex(ValueError, 'colliding'):
            PACKAGE.export_revision(self.source, tree, target, self.root / 'objects')
        self.assertEqual(list(target.iterdir()), [])
        self.assertEqual(list(outside.iterdir()), [])

    def test_rejects_unicode_aliases_before_writing(self):
        blob = self.git(self.source, 'rev-parse', 'HEAD:main.go')
        for names in [('File', 'file'), ('caf\u00e9', 'cafe\u0301')]:
            with self.subTest(names=names):
                tree = self.git(self.source, 'mktree',
                                input=''.join(f'100644 blob {blob}\t{name}\n' for name in names))
                target = self.root / ('export-' + names[0])
                target.mkdir()
                with self.assertRaisesRegex(ValueError, 'colliding'):
                    PACKAGE.export_revision(self.source, tree, target, self.root / 'objects')
                self.assertEqual(list(target.iterdir()), [])

    def test_rejects_corrupted_blob_before_writing(self):
        target = self.root / 'export'
        target.mkdir()
        original_run = subprocess.run
        def corrupt(args, **kwargs):
            result = original_run(args, **kwargs)
            if 'cat-file' in args:
                raw = Path(kwargs['stdout'].name)
                raw.write_bytes(raw.read_bytes().replace(b'package main\n', b'package evil\n'))
            return result
        with patch.object(PACKAGE.subprocess, 'run', side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, 'recorded object ID'):
                PACKAGE.export_revision(self.source, self.git(self.source, 'rev-parse', 'HEAD'),
                                        target, self.root / 'objects')
        self.assertEqual(list(target.iterdir()), [])

    def test_rejects_existing_export_contents(self):
        target = self.root / 'export'
        target.mkdir()
        (target / 'main.go').symlink_to(self.source / 'main.go')
        with self.assertRaisesRegex(ValueError, 'empty private directory'):
            PACKAGE.export_revision(self.source, self.git(self.source, 'rev-parse', 'HEAD'),
                                    target, self.root / 'objects')

    def test_rejects_untracked_source_before_building(self):
        (self.source / 'untracked.go').write_text('package main\n')
        with self.assertRaisesRegex(ValueError, 'committed and clean'):
            self.package()
        self.assertFalse(self.log.exists())

    def test_rejects_source_symlinks_outside_recorded_tree(self):
        (self.source / 'outside.go').symlink_to('../unrecorded.go')
        self.git(self.source, 'add', '.')
        self.git(self.source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'external symlink')
        with self.assertRaisesRegex(ValueError, 'symlink escapes'):
            self.package()
        self.assertFalse(self.log.exists())

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
        call = json.loads(self.log.read_text().splitlines()[0])
        self.assertFalse(Path(call['cwd']).exists())

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
