#!/usr/bin/env python3
"""Build an ARM64 agent and local BitBake layer from committed inputs."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile


SERVICE_FILES = (
    'wendyos-agent.service',
    'wendyos-agent-updater.service',
    'wendyos-agent-updater.timer',
    'wendyos-agent-updater.sh',
    'download-wendyos-agent.sh',
)


def run(*args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, **kwargs).strip()


def clean_revision(repository):
    if run('git', '-C', repository, 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError(f'checkout must be committed and clean: {repository}')
    return (
        run('git', '-C', repository, 'rev-parse', 'HEAD'),
        run('git', '-C', repository, 'rev-parse', 'HEAD^{tree}'),
    )


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
        path: subprocess.check_output(['git', '-C', str(builder), 'show', f'{builder_commit}:{path}'])
        for path in paths
    }
    compatibility = next(
        line.split('=', 1)[1].strip().strip('"')
        for line in inputs['conf/layer.conf'].decode().splitlines()
        if line.startswith('LAYERSERIES_COMPAT_wendyos =')
    )

    out.mkdir(parents=True)
    binary = out / 'wendy-agent'
    # A developer's surrounding go.work or persistent GOFLAGS must not select
    # extra source or flags outside the recorded checkout/build invocation.
    env = dict(os.environ, CGO_ENABLED='0', GOOS='linux', GOARCH='arm64',
               GOWORK='off', GOENV='off', GOFLAGS='')
    flags = '-s -w -X github.com/wendylabsinc/wendy/go/internal/shared/version.Version=' + version
    build_flags = ['-mod=readonly', '-trimpath', '-ldflags', flags]
    subprocess.run([go, 'build', *build_flags, '-o', str(binary), './go/cmd/wendy-agent'],
                   cwd=source, env=env, check=True)
    if clean_revision(source) != (commit, tree):
        raise ValueError('source revision changed during the build')
    data = binary.read_bytes()
    if len(data) < 20 or data[:4] != b'\x7fELF' or int.from_bytes(data[18:20], 'little') != 183:
        raise ValueError('expected ARM64 ELF')

    # The binary reports the compiler that actually built it, including an
    # automatically selected Go toolchain. A bare `go version` may report the
    # launcher instead, particularly outside the source module's directory.
    build_info = run(go, 'version', '-m', binary, cwd=source, env=env).splitlines()
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
        'builder_commit': builder_commit,
        'builder_tree': builder_tree,
        'builder_files_sha256': {path: hashlib.sha256(content).hexdigest() for path, content in inputs.items()},
        'go_version': go_version,
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
