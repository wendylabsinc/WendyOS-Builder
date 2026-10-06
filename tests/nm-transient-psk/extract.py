#!/usr/bin/env python3
"""Extract complete production function bodies; do not reimplement their decisions."""
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
names = [
    'need_new_wpa_psk',
    'has_matching_stored_psk',
    'handle_8021x_or_psk_auth_fail',
    'supplicant_iface_notify_wpa_psk_mismatch_cb',
    'supplicant_connection_timeout_cb',
]
parts = []
for name in names:
    match = re.search(r'^static (?:gboolean|void)\n' + name + r'\([^\n]*(?:\n.*?)?^}\n',
                      source, re.M | re.S)
    if not match:
        if name == 'has_matching_stored_psk':  # absent in unpatched baseline
            continue
        sys.exit('ERROR: production function not found: ' + name)
    parts.append(match.group())
parts[0:0] = re.findall(r'^#define STORED_PSK_.*$', source, re.M)
(out / 'handlers.inc').write_text('\n'.join(parts))
