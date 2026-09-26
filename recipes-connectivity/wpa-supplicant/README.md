# Host Wi-Fi Aware support

This layer upgrades wpa_supplicant to hostap 2.12, enables NAN/PASN, and
installs `wendyos-nan` for host-shell control. The `wpa_supplicant.service`
drop-in adds a global control socket while retaining the D-Bus interface used
by NetworkManager. The add-on requires a NAN-capable driver, such as the BE202
bundle in the parent branch; installing the supplicant alone does not add radio
support.

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

The intended agent carrier uses **unencrypted NAN data paths** and puts Wendy
device mTLS QUIC above them. Until that carrier is installed, manual NDP
traffic has no Wendy link encryption. Limit this host-shell tool to trusted
operators and networks. The NAN lifecycle patch repairs local cleanup paths;
it does not resolve the rare lower-layer NDP data-plane stall documented in
`nan/jetson/notes/22-ndp-data-plane-root-cause.md` in the parent workspace.

Local validation: run `sh wpa-supplicant/wendyos-nan.test.sh` and ShellCheck.
The five patches apply in order to the pinned hostap 2.12 tarball. Patch 0005
accepts an informational, unselected NDC in an NDL Request so an Android
Pixel 7 can negotiate an NDP with the Pi 5. The responder still selects its
own NDC, and Response/Confirm frames still require a selected NDC. The
regression fixture uses the Pixel's captured NDC bytes. Cross-vendor NDP and
camera-protocol hardware acceptance is tracked with the Pi camera demo.
