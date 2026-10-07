#!/usr/bin/env python3
"""Extract production policy code; do not reimplement its decisions."""
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
parts = []
for name in ['reset_connections_retries', '_connection_autoconnect_retries_set',
             'has_saved_wifi_psk']:
    match = re.search(r'^static (?:gboolean|void)\n' + name + r'\([^\n]*(?:\n.*?)?^}\n',
                      source, re.M | re.S)
    if not match:
        if name == 'has_saved_wifi_psk':  # absent in unpatched baseline
            continue
        sys.exit('ERROR: production function not found: ' + name)
    parts.append(match.group())
# The callback also handles routing, DNS and modems. Compile its complete FAILED
# case unchanged, with only the surrounding callback arguments/locals supplied.
callback = source.split('\ndevice_state_changed(', 1)[1]
match = re.search(r'^    case NM_DEVICE_STATE_FAILED:\n.*?(?=^    case NM_DEVICE_STATE_ACTIVATED:)',
                  callback, re.M | re.S)
if not match:
    sys.exit('ERROR: production FAILED case not found')
parts.append('''static void failure(NMDevice *device, int old_state, int reason) {
    NMPolicy *self = &policy;
    NMPolicyPrivate *priv = NM_POLICY_GET_PRIVATE(self);
    NMSettingsConnection *sett_conn = device->settings;
    switch (NM_DEVICE_STATE_FAILED) {
''' + match.group() + '}\n}\n')
(out / 'handlers.inc').write_text('\n'.join(parts))
