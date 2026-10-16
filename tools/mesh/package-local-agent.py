#!/usr/bin/env python3
"""Build an ARM64 agent and local BitBake layer from committed inputs."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import subprocess
import tarfile
import tempfile
import unicodedata


SERVICE_FILES = (
    'wendyos-agent.service',
    'wendyos-agent-updater.service',
    'wendyos-agent-updater.timer',
    'wendyos-agent-updater.sh',
    'download-wendyos-agent.sh',
)


def run(*args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, **kwargs).strip()


def git_env():
    # Replacement refs can change bytes without changing the reported object ID.
    return dict(os.environ, GIT_NO_REPLACE_OBJECTS='1')


def clean_revision(repository):
    if run('git', '-C', repository, 'status', '--porcelain', '--untracked-files=all', env=git_env()):
        raise ValueError(f'checkout must be committed and clean: {repository}')
    commit = run('git', '-C', repository, 'rev-parse', 'HEAD', env=git_env())
    return commit, run('git', '-C', repository, 'rev-parse', f'{commit}^{{tree}}', env=git_env())


def export_revision(repository, commit, destination, objects):
    # Read raw tree/blob objects: git archive honors export-ignore/export-subst
    # from committed, repository-local and global attributes. A build must keep
    # every recorded source byte regardless of those distribution preferences.
    destination = destination.resolve()
    if any(destination.iterdir()):
        raise ValueError('source export requires an empty private directory')
    listing = subprocess.check_output([
        'git', '-C', str(repository), 'ls-tree', '-rz', '--full-tree', commit,
    ], env=git_env())
    entries = []
    paths = {}
    for entry in listing.split(b'\0'):
        if not entry:
            continue
        metadata, name = entry.split(b'\t', 1)
        mode, kind, oid = metadata.split()
        if kind != b'blob' or mode not in (b'100644', b'100755', b'120000'):
            raise ValueError(f'unsupported source tree entry: {os.fsdecode(name)}')
        relative = PurePosixPath(os.fsdecode(name))
        if relative.is_absolute() or any(part in ('', '.', '..') for part in os.fsdecode(name).split('/')):
            raise ValueError(f'unsafe source path: {relative}')
        # Git is case-sensitive; the export filesystem may not be. Reject
        # aliases (including Unicode normalization) before creating anything.
        for index in range(1, len(relative.parts) + 1):
            prefix = relative.parts[:index]
            key = tuple(unicodedata.normalize('NFC', part).casefold() for part in prefix)
            directory = index < len(relative.parts)
            if '.git' in key or (key in paths and paths[key] != (prefix, True)):
                raise ValueError(f'colliding or reserved source path: {relative}')
            if key in paths and not directory:
                raise ValueError(f'colliding source path: {relative}')
            paths[key] = (prefix, directory)
        entries.append((mode, oid, destination.joinpath(*relative.parts)))
    with objects.open('wb') as raw:
        subprocess.run(['git', '-C', str(repository), 'cat-file', '--batch'],
                       input=b''.join(oid + b'\n' for _, oid, _ in entries),
                       stdout=raw, check=True, env=git_env())
    blobs = []
    links = []
    with objects.open('rb') as raw:
        for mode, oid, path in entries:
            actual_oid, kind, length = raw.readline().split()
            if actual_oid != oid or kind != b'blob':
                raise ValueError('unexpected source object')
            offset = raw.tell()
            data = raw.read(int(length))
            if len(data) != int(length) or raw.read(1) != b'\n':
                raise ValueError('truncated source object')
            algorithm = 'sha1' if len(oid) == 40 else 'sha256'
            digest = hashlib.new(algorithm, b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
            if digest.encode() != oid:
                raise ValueError('source blob does not match its recorded object ID')
            if mode == b'120000':
                target = os.fsdecode(data)
                resolved = posixpath.normpath(str(path.relative_to(destination).parent / target))
                if not target or '\0' in target or target.startswith('/') or resolved == '..' or resolved.startswith('../'):
                    raise ValueError(f'source symlink escapes the recorded tree: {path}')
                links.append((path, target))
            else:
                blobs.append((mode, path, offset, len(data)))
        # No symlink exists while regular files are written. Exclusive creation
        # also refuses aliases not covered by our portable-name checks.
        for mode, path, offset, length in blobs:
            path.parent.mkdir(parents=True, exist_ok=True)
            raw.seek(offset)
            with path.open('xb') as output:
                output.write(raw.read(length))
                path.chmod(0o755 if mode == b'100755' else 0o644)
    for path, target in links:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
    for path, _ in links:
        try:
            resolved = path.resolve()
        except (RuntimeError, OSError) as error:
            raise ValueError(f'invalid source symlink: {path}') from error
        if not resolved.is_relative_to(destination):
            raise ValueError(f'source symlink escapes the recorded tree: {path}')


def package_agent(source, out, go, version, builder):
    source, out, builder = source.resolve(), out.resolve(), builder.resolve()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', version):
        raise ValueError('unsafe version')
    if out.exists():
        raise ValueError('fresh output directory required')
    if out.is_relative_to(source) or out.is_relative_to(builder):
        raise ValueError('output must be outside the source and Builder checkouts')
    commit, tree = clean_revision(source)
    builder_commit, builder_tree = clean_revision(builder)

    # Read the layer inputs from the recorded commit, so a later checkout/edit
    # cannot silently change the service files copied into this build.
    paths = [f'recipes-core/wendyos-agent/files/{name}' for name in SERVICE_FILES]
    paths += ['conf/layer.conf', 'tools/mesh/package-local-agent.py']
    inputs = {
        path: subprocess.check_output(['git', '-C', str(builder), 'show', f'{builder_commit}:{path}'], env=git_env())
        for path in paths
    }
    compatibility = next(
        line.split('=', 1)[1].strip().strip('"')
        for line in inputs['conf/layer.conf'].decode().splitlines()
        if line.startswith('LAYERSERIES_COMPAT_wendyos =')
    )

    out.mkdir(parents=True)
    binary = out / 'wendy-agent'
    go_path = shutil.which(str(go))
    if go_path is None:
        raise ValueError(f'Go executable not found: {go}')
    go = str(Path(go_path).resolve())
    go_launcher_sha = hashlib.sha256(Path(go).read_bytes()).hexdigest()
    # A developer's surrounding go.work or persistent GOFLAGS must not select
    # extra source or flags outside the recorded checkout/build invocation.
    env = dict(os.environ, CGO_ENABLED='0', GOOS='linux', GOARCH='arm64',
               GOWORK='off', GOENV='off', GOFLAGS='')
    flags = '-s -w -X github.com/wendylabsinc/wendy/go/internal/shared/version.Version=' + version
    build_flags = ['-mod=readonly', '-trimpath', '-ldflags', flags]
    # A clean checkout can contain ignored Go files, and its tracked files can
    # change while the compiler reads them. Export the pinned commit into a
    # private directory so neither can influence the packaged binary.
    with tempfile.TemporaryDirectory(prefix='wendy-agent-source-') as temporary:
        snapshot = Path(temporary) / 'source'
        snapshot.mkdir()
        export_revision(source, commit, snapshot, Path(temporary) / 'objects')
        subprocess.run([go, 'build', *build_flags, '-o', str(binary), './go/cmd/wendy-agent'],
                       cwd=snapshot, env=env, check=True)

        # Resolve automatic toolchain selection against the same exported module.
        build_info = run(go, 'version', '-m', binary, cwd=snapshot, env=env).splitlines()
    if hashlib.sha256(Path(go).read_bytes()).hexdigest() != go_launcher_sha:
        raise ValueError('Go launcher changed during the build')
    if clean_revision(source) != (commit, tree):
        raise ValueError('source revision changed during the build')
    data = binary.read_bytes()
    if len(data) < 20 or data[:4] != b'\x7fELF' or int.from_bytes(data[18:20], 'little') != 183:
        raise ValueError('expected ARM64 ELF')

    # The binary reports the compiler that actually built it, including an
    # automatically selected Go toolchain. A bare `go version` may report the
    # launcher instead, particularly outside the source module's directory.
    prefix = f'{binary}: '
    if not build_info or not build_info[0].startswith(prefix):
        raise ValueError('could not read the binary Go compiler version')
    go_version = build_info[0][len(prefix):]

    files = out / 'layer/recipes-core/wendyos-agent/files'
    files.mkdir(parents=True)
    archive = files / f'wendy-agent-linux-arm64-{version}.tar.gz'
    with archive.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as compressed, tarfile.open(fileobj=compressed, mode='w') as tar:
        info = tarfile.TarInfo('wendy-agent-linux-arm64/wendy-agent')
        info.mode = 0o755
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    archive_sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    for name in SERVICE_FILES:
        (files / name).write_bytes(inputs[f'recipes-core/wendyos-agent/files/{name}'])

    conf = out / 'layer/conf'
    conf.mkdir()
    (conf / 'layer.conf').write_text(
        'BBPATH .= ":${LAYERDIR}"\n'
        'BBFILES += "${LAYERDIR}/recipes-*/*/*.bbappend"\n'
        'BBFILE_COLLECTIONS += "wendy_local_agent"\n'
        'BBFILE_PATTERN_wendy_local_agent = "^${LAYERDIR}/"\n'
        'BBFILE_PRIORITY_wendy_local_agent = "100"\n'
        f'LAYERSERIES_COMPAT_wendy_local_agent = "{compatibility}"\n'
    )
    service_files = ' '.join('file://' + name for name in SERVICE_FILES)
    append = f'''# Generated from WendyOS {commit}; unpublished local acceptance input.
FILESEXTRAPATHS:prepend := "${{THISDIR}}/files:"
WENDYOS_AGENT_VERSION = "{version}"
WENDYOS_AGENT_SHA256 = "{archive_sha}"
SRC_URI = "file://{archive.name};name=agent {service_files}"
SRC_URI[agent.sha256sum] = "{archive_sha}"
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
SYSTEMD_SERVICE:${{PN}} = "wendyos-agent.service"
do_install:append() {{
    install -d ${{D}}${{sysconfdir}}/systemd/system
    ln -sf /dev/null ${{D}}${{sysconfdir}}/systemd/system/wendyos-agent-updater.timer
}}
FILES:${{PN}}:append = " ${{sysconfdir}}/systemd/system/wendyos-agent-updater.timer"
'''
    (files.parent / 'wendyos-agent_1.0.bbappend').write_text(append)
    manifest = {
        'kind': 'unpublished-local-agent-layer',
        'source_commit': commit,
        'source_tree': tree,
        'source_export': 'raw-git-tree-blobs',
        'builder_commit': builder_commit,
        'builder_tree': builder_tree,
        'builder_files_sha256': {path: hashlib.sha256(content).hexdigest() for path, content in inputs.items()},
        'go_version': go_version,
        # Automatic toolchain selection may use a different compiler; its
        # version is recorded above. This hash identifies only the launcher.
        'go_launcher_path': go,
        'go_launcher_sha256': go_launcher_sha,
        'go_build_info': '\n'.join(build_info[1:]),
        'version': version,
        'binary_sha256': hashlib.sha256(data).hexdigest(),
        'archive_sha256': archive_sha,
        'build_flags': build_flags,
        'updater_masked': True,
        'hardware_acceptance': False,
        'bitbake_validation': 'PENDING',
        'runtime_validation': 'PENDING',
    }
    (out / 'BUILD-PROVENANCE.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--go', default='go')
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    builder = Path(__file__).resolve().parents[2]
    try:
        manifest = package_agent(args.source, args.output, args.go, args.version, builder)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
