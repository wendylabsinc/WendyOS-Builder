#!/usr/bin/env python3
"""Extract complete production function bodies; do not reimplement their decisions."""
import pathlib,re,sys
source=pathlib.Path(sys.argv[1]).read_text()
out=pathlib.Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
names=['need_new_wpa_psk','allow_transient_psk_timeout','handle_8021x_or_psk_auth_fail','supplicant_iface_notify_wpa_psk_mismatch_cb','supplicant_connection_timeout_cb']
parts=[]
for name in names:
    m=re.search(r'^static (?:gboolean|void)\n'+name+r'\([^\n]*(?:\n.*?)?^}\n',source,re.M|re.S)
    if not m:
        if name=='allow_transient_psk_timeout':continue
        raise AssertionError('function not found '+name)
    parts.append(m.group())
define=re.search(r'^#define TRANSIENT_PSK_TIMEOUT_ALLOWED .*$',source,re.M)
if define:parts.insert(0,define.group())
(out/'handlers.inc').write_text('\n'.join(parts))
