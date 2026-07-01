# Make crun a drop-in replacement for runc on WendyOS.
#
# The base crun recipe (meta-virtualization) installs only /usr/bin/crun. To
# replace runc system-wide we need crun to:
#   1. Satisfy the virtual-runc dependency that containerd-opencontainers pulls
#      in via ${VIRTUAL-RUNTIME_container_runtime}.
#   2. Be reachable under the "runc" binary name, since containerd-shim-runc-v2
#      (and nerdctl / ctr) exec a binary literally named "runc" by default.

# Resolve containerd's RDEPENDS on virtual-runc to crun.
RPROVIDES:${PN} += "virtual-runc"
PROVIDES += "virtual/runc"

# Expose crun under the "runc" name via update-alternatives so /usr/bin/runc
# resolves to crun for every consumer. Using alternatives (rather than a bare
# symlink) keeps the swap clean if runc-opencontainers is ever reintroduced.
inherit update-alternatives
ALTERNATIVE_PRIORITY = "100"
ALTERNATIVE:${PN} = "runc"
ALTERNATIVE_LINK_NAME[runc] = "${bindir}/runc"
ALTERNATIVE_TARGET[runc] = "${bindir}/crun"
