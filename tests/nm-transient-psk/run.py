#!/usr/bin/env python3
"""Compile exact recipe source functions, compare baseline failure and patched success.

Only NM platform/secret-agent calls are replaced with side-effect recording stubs.
Request ownership uses real GLib GObject storage. This is not a full D-Bus daemon test.
"""
import argparse, hashlib, json, pathlib, resource, shutil, subprocess, sys
here=pathlib.Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--upstream',type=pathlib.Path,required=True);parser.add_argument('--output',type=pathlib.Path,required=True)
a=parser.parse_args();a.output.mkdir(parents=True,exist_ok=False)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
source=a.upstream/'src/core/devices/wifi/nm-device-wifi.c'
expected='e83faed72137306c842411d1a28bce9618932d1648c8493b895df3e110b4455b'
assert hashlib.sha256(source.read_bytes()).hexdigest()==expected,'requires exact NM1.56.0 source'
patch=here.parents[1]/'recipes-connectivity/networkmanager/files/0001-wifi-bound-transient-stored-key-timeout.patch'
patched=a.output/'patched';target=patched/'src/core/devices/wifi/nm-device-wifi.c';target.parent.mkdir(parents=True);shutil.copy2(source,target)
p=subprocess.run(['patch','--batch','-p1','-i',str(patch)],cwd=patched,text=True,capture_output=True)
(a.output/'patch.log').write_text(p.stdout+p.stderr);assert p.returncode==0
flags=subprocess.check_output(['pkg-config','--cflags','--libs','gobject-2.0'],text=True).split()
result={}
for label,path in [('baseline',source),('candidate',target)]:
    out=a.output/label;out.mkdir()
    subprocess.run([sys.executable,str(here/'extract.py'),str(path),str(out)],check=True)
    binary=out/'harness'
    subprocess.run(['cc','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-unused-function','-g','-I'+str(out),str(here/'harness.c'),*flags,'-o',str(binary)],check=True)
    r=subprocess.run([str(binary)],capture_output=True,text=True)
    (out/'run.log').write_text(r.stdout+r.stderr)
    if label=='baseline':
        assert r.returncode==-6 and "'disconnect_reason(15)' should be FALSE" in r.stderr,(r.returncode,r.stderr)
    else:
        assert r.returncode==0 and 'ALL 19 exact-source handler groups PASS' in r.stdout,(r.returncode,r.stderr)
    result[label]={'exit':r.returncode,'source_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'functions_sha256':hashlib.sha256((out/'handlers.inc').read_bytes()).hexdigest()}
(a.output/'RESULT.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS: exact upstream negative and candidate 19-group positive')
