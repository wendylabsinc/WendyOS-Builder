# blacksail bring-up compatibility bridge (JetPack 7.2 / L4T R39.2.0 experiment).
#
# As of 2026-06-15 the core stack (oe-core, meta-yocto, meta-tegra
# wip-l4t-r39.2.0, meta-tegra-community wip-l4t-r39.2.0) all declare
# LAYERSERIES_COMPAT = "blacksail", but meta-openembedded and
# meta-virtualization master have NOT yet bumped past wrynose:
#
#   meta-oe        openembedded-layer  -> "whinlatter wrynose"
#   meta-python    meta-python         -> "whinlatter wrynose"
#   meta-networking networking-layer   -> (tracks the same)
#   meta-filesystems filesystems-layer -> (tracks the same)
#   meta-multimedia multimedia-layer   -> (tracks the same)
#   meta-virt      virtualization-layer-> "wrynose"
#
# meta-tegra-community LAYERDEPENDS requires openembedded-layer + meta-python,
# so without this bridge bitbake's sanity check aborts the parse with
# "Layer X is not compatible with the core layer which only supports these
# series: blacksail".
#
# These appends assert "trust me, this layer parses on blacksail" — the
# standard escape hatch for bleeding-edge bring-up. They are GATED on
# WENDYOS_LAYER_TREE == "blacksail" so they are completely inert on the
# validated wrynose/scarthgap trees (and on main). The real fix is upstream
# bumping these layers' LAYERSERIES_COMPAT; when that lands, re-pin the
# SRCREVs in repos.overrides and delete this file + its require line.
#
# NOTE: this only silences the version *gate*. Any genuine API breakage
# blacksail introduced in oe-core that these layers rely on will still fail
# at parse/build time — which is exactly the "what breaks" signal we want.

_BLACKSAIL_COMPAT = "${@' blacksail' if d.getVar('WENDYOS_LAYER_TREE') == 'blacksail' else ''}"

LAYERSERIES_COMPAT_openembedded-layer:append = "${_BLACKSAIL_COMPAT}"
LAYERSERIES_COMPAT_meta-python:append = "${_BLACKSAIL_COMPAT}"
LAYERSERIES_COMPAT_networking-layer:append = "${_BLACKSAIL_COMPAT}"
LAYERSERIES_COMPAT_filesystems-layer:append = "${_BLACKSAIL_COMPAT}"
LAYERSERIES_COMPAT_multimedia-layer:append = "${_BLACKSAIL_COMPAT}"
LAYERSERIES_COMPAT_virtualization-layer:append = "${_BLACKSAIL_COMPAT}"

# [NOTE]
# meta-raspberrypi's blacksail bridge is intentionally NOT here.
# LAYERSERIES_COMPAT is snapshotted + checked during the layer.conf loop
# (cookerdata.py), BEFORE this file (a local.conf postfile) is parsed — so a
# bridge here is too late to be seen. It lives in bblayers/rpi-blacksail.inc
# (a bblayers include, parsed in time). The meta-oe/meta-virt appends above are
# likewise ineffective for the *gate*, but those layers already intersect
# LAYERSERIES_CORENAMES on "wrynose", so they pass without a bridge anyway.

