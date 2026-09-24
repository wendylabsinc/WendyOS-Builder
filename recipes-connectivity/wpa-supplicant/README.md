# Host Wi-Fi Aware support

This layer upgrades wpa_supplicant to hostap 2.12, enables NAN/PASN, and
installs `wendyos-nan` for host-shell control. The `wpa_supplicant.service`
drop-in adds a global control socket while retaining the D-Bus interface used
by NetworkManager. The add-on requires a NAN-capable driver, such as the BE202
bundle already on `main`; installing the supplicant alone does not add radio
support.

The helper automatically selects the single NAN-capable radio registered with
the shared supplicant. If several radios support NAN, select a parent explicitly
with `WENDYOS_NAN_PARENT_IFACE=wlan0`. Only P2P management devices on that radio
are removed. Data interfaces are created on the management interface's radio,
independently of the order in which NetworkManager or other callers registered
interfaces. The local control-interface patch supplies the explicit parent
argument and radio identities needed for this selection.

Failed or invalid control queries return an error; they are not treated as
evidence that an interface is absent or stopped. Failed starts clean up only a
management interface created by that invocation, preserving existing sessions.

Typical manual flow on two devices:

```sh
wendyos-nan start
wendyos-nan schedule-default
wendyos-nan ndi-create
wendyos-nan publish-sync service_name=wendy.mesh
# On the other device:
wendyos-nan subscribe-sync service_name=wendy.mesh
wendyos-nan events
```

Use the returned peer NMI and publication/subscription handle with
`ndp-request`; the peer accepts with `ndp-respond`. `ndp-terminate` and
`wendyos-nan stop` release the data path. `wendyos-nan command` exposes the
underlying control interface for diagnostics. The helper intentionally does
not assign IP addresses or start a mesh agent.

Normal `stop` preserves station Wi-Fi and leaves P2P restoration deferred. Use
`wendyos-nan restore-p2p` after stopping NAN when P2P functionality is needed;
that explicit operation restarts the shared supplicant and interrupts station
Wi-Fi. Restoration requires every NAN management interface to be removed,
including interfaces with other names or on other radios; missing or invalid
interface-type metadata prevents the restart. The lifecycle lock coordinates
helper callers, but direct control-socket access and the raw `command` escape
hatch remain unmanaged operator interfaces.

The intended agent carrier uses **unencrypted NAN data paths** and puts Wendy
device mTLS QUIC above them. Until that carrier is installed, manual NDP
traffic has no Wendy link encryption. Limit this host-shell tool to trusted
operators and networks. The NAN lifecycle patch repairs local cleanup paths;
it does not resolve the rare lower-layer NDP data-plane stall documented in
`nan/jetson/notes/22-ndp-data-plane-root-cause.md` in the parent workspace.

Local validation, from this directory:

```sh
sh wpa-supplicant/wendyos-nan.test.sh
sh wpa-supplicant/wendyos-nan-stop.test.sh
python3 wpa-supplicant/wendyos-nan-lifecycle.test.py -v
shellcheck wpa-supplicant/wendyos-nan wpa-supplicant/*.test.sh
# After applying all five patches to the pinned source:
python3 wpa-supplicant/wendyos-nan-parent.test.py /path/to/wpa_supplicant-2.12
```

The Linux lifecycle fixtures cover concurrent callers, control-query failures,
rollback ownership, capable-radio selection and preservation of unrelated P2P
devices. The C fixture compiles the actual patched interface-control functions
with two driver stubs to check parent selection and removal/rollback on the
correct radio. These fixtures do not exercise firmware, actual NDP traffic or
complete image builds; those require separate target and hardware checks.
