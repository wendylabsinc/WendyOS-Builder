#!/usr/bin/env python3
"""Build an exact-source ARM64 agent and a reproducible local BitBake layer."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

def run(*args, **kwargs):
    return subprocess.check_output(list(map(str,args)), text=True, **kwargs).strip()

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--go',default='go')
    p.add_argument('--version',required=True)
    a=p.parse_args(); source=a.source.resolve(); out=a.output.resolve()
    assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*',a.version), 'unsafe version'
    assert not run('git','-C',source,'status','--porcelain'), 'source must be committed and clean'
    assert not out.exists(), 'fresh output directory required'
    commit=run('git','-C',source,'rev-parse','HEAD')
    tree=run('git','-C',source,'rev-parse','HEAD^{tree}')
    out.mkdir(parents=True)
    binary=out/'wendy-agent'
    env=dict(os.environ,CGO_ENABLED='0',GOOS='linux',GOARCH='arm64')
    flags='-s -w -X github.com/wendylabsinc/wendy/go/internal/shared/version.Version='+a.version
    subprocess.run([a.go,'build','-trimpath','-ldflags',flags,'-o',str(binary),'./go/cmd/wendy-agent'],cwd=source,env=env,check=True)
    data=binary.read_bytes()
    assert data[:4]==b'\x7fELF' and int.from_bytes(data[18:20],'little')==183, 'expected ARM64 ELF'
    files=out/'layer/recipes-core/wendyos-agent/files'; files.mkdir(parents=True)
    archive=files/('wendy-agent-linux-arm64-'+a.version+'.tar.gz')
    with archive.open('wb') as raw, gzip.GzipFile(fileobj=raw,mode='wb',filename='',mtime=0) as compressed, tarfile.open(fileobj=compressed,mode='w') as tar:
        info=tarfile.TarInfo('wendy-agent-linux-arm64/wendy-agent')
        info.mode=0o755; info.size=len(data); tar.addfile(info,io.BytesIO(data))
    archive_sha=hashlib.sha256(archive.read_bytes()).hexdigest()
    builder=Path(__file__).resolve().parents[2]
    for name in ['wendyos-agent.service','wendyos-agent-updater.service','wendyos-agent-updater.timer','wendyos-agent-updater.sh','download-wendyos-agent.sh']:
        shutil.copy2(builder/'recipes-core/wendyos-agent/files'/name,files/name)
    conf=out/'layer/conf'; conf.mkdir()
    compatibility=next(line.split('=',1)[1].strip().strip(chr(34)) for line in (builder/'conf/layer.conf').read_text().splitlines() if line.startswith('LAYERSERIES_COMPAT_wendyos ='))
    (conf/'layer.conf').write_text('BBPATH .= ":${LAYERDIR}"\nBBFILES += "${LAYERDIR}/recipes-*/*/*.bbappend"\nBBFILE_COLLECTIONS += "wendy_local_agent"\nBBFILE_PATTERN_wendy_local_agent = "^${LAYERDIR}/"\nBBFILE_PRIORITY_wendy_local_agent = "100"\nLAYERSERIES_COMPAT_wendy_local_agent = "'+compatibility+'"\n')
    service_files=' '.join('file://'+f for f in ['wendyos-agent.service','wendyos-agent-updater.service','wendyos-agent-updater.timer','wendyos-agent-updater.sh','download-wendyos-agent.sh'])
    append=f'''# Generated from WendyOS {commit}; unpublished local acceptance input.
FILESEXTRAPATHS:prepend := "${{THISDIR}}/files:"
WENDYOS_AGENT_VERSION = "{a.version}"
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
    (files.parent/'wendyos-agent_1.0.bbappend').write_text(append)
    manifest={'kind':'unpublished-local-agent-layer','source_commit':commit,'source_tree':tree,'builder_commit':run('git','-C',builder,'rev-parse','HEAD'),'go_version':run(a.go,'version'),'version':a.version,'binary_sha256':hashlib.sha256(data).hexdigest(),'archive_sha256':archive_sha,'build_flags':['-trimpath','-ldflags',flags],'updater_masked':True,'hardware_acceptance':False,'bitbake_validation':'PENDING','runtime_validation':'PENDING'}
    (out/'BUILD-PROVENANCE.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest,indent=2))

if __name__=='__main__': main()
