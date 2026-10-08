# Host Wi-Fi Aware support

Wi-Fi Aware (NAN) lets nearby devices discover each other and establish direct
Wi-Fi connections without an access point. This layer upgrades wpa_supplicant
to hostap 2.12, enables its NAN/PASN support, and installs `wendyos-nan` to
manage the host interfaces. It requires a capable driver, such as the BE202
bundle already on `main`; installing the supplicant alone does not add radio
support. NetworkManager continues to use the same supplicant for ordinary Wi-Fi.

## Why ship `wendyos-nan`?

The helper is an OS dependency of the agent features later in the mesh stack.
It packages radio selection, interface creation, locking and failure cleanup
into operations that both agent callers can reuse:

- The NAN mesh carrier calls `status`, `start`, `schedule-default`, `ndi-create`,
  `ndi-remove` and `stop` to bring up its connection path and recover from failures.
- The `nan` app entitlement calls `start` and `ndi-create` when preparing an
  app, then `ndi-remove` when releasing that app's data interface.

The agent and entitled apps communicate directly with the supplicant socket
for discovery and connection negotiation. Application traffic does not pass
through this script. Its publish/subscribe, data-path and event commands are
also available for manual testing and diagnostics.

The service drop-in adds the global control socket used for interface management
while retaining the D-Bus interface used by NetworkManager. The helper does not
assign IP addresses, implement routing or decide which app owns a session;
those responsibilities remain with its callers.

## Lifecycle and manual use

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
Existing interface names are accepted only when the supplicant confirms the
expected management or data-interface type. Missing or malformed type metadata
causes an error, so an interface-name collision cannot remove ordinary Wi-Fi.

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
underlying control interface for diagnostics.

Normal `stop` preserves station Wi-Fi and leaves P2P restoration deferred. Use
`wendyos-nan restore-p2p` after stopping NAN when P2P functionality is needed;
that explicit operation restarts the shared supplicant and interrupts station
Wi-Fi. Restoration requires every NAN management interface to be removed,
including interfaces with other names or on other radios; missing or invalid
interface-type metadata prevents the restart. The lifecycle lock coordinates
helper callers, but direct control-socket access and the raw `command` escape
hatch remain unmanaged operator interfaces.
Removing NAN interfaces also skips the supplicant's global Wi-Fi Direct group
cleanup, preserving active Wi-Fi Direct connections on other radios.

The intended agent carrier uses **unencrypted NAN data paths** and puts Wendy
device mTLS QUIC above them. Until that carrier is installed, manual NDP
traffic has no Wendy link encryption. Limit manual use to trusted operators
and networks. The NAN lifecycle patch repairs local cleanup paths;
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
rollback ownership, interface-type validation, capable-radio selection and
preservation of unrelated P2P devices. The C fixture compiles the actual patched
interface-control functions with two driver stubs to check parent selection,
removal/rollback on the correct radio, context lifetime during recursive child
removal, and preservation of other-radio Wi-Fi Direct groups during NAN teardown.
These fixtures do not exercise firmware, actual NDP traffic or
complete image builds; those require separate target and hardware checks.
