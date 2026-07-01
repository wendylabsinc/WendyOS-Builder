SUMMARY = "wendy-mesh chained CNI plugin"
DESCRIPTION = "Stateless CNI plugin that routes a meshed container's egress to \
the mesh service CIDR. Chained after bridge+portmap; driven entirely by the \
agent via a versioned CNI runtimeConfig contract."
LICENSE = "MIT"
# NOTE: this md5 was computed directly from the committed src/LICENSE (it
# carries a copyright line, so it differs from the bare MIT template hash in
# COMMON_LICENSE_DIR/MIT). Computed with:
#   md5 recipes-networking/wendy-mesh-cni/src/LICENSE
LIC_FILES_CHKSUM = "file://src/LICENSE;md5=382861ee89f2ea998f59ae5411c3ce3d"

# In-repo Go source (committed under src/, incl. vendor/). Built offline.
GO_IMPORT = "github.com/wendylabsinc/wendyos-builder/wendy-mesh-cni"

FILESEXTRAPATHS:prepend := "${THISDIR}:"
SRC_URI = "file://src;subdir=${BP}/src/${GO_IMPORT}"

S = "${WORKDIR}/${BP}"
GO_SRCDIR = "${S}/src/${GO_IMPORT}"

inherit go-mod

# Build only the plugin command; offline from committed vendor/ (reproducible).
GO_INSTALL = "${GO_IMPORT}/cmd/wendy-mesh"
GOBUILDFLAGS:append = " -mod=vendor -buildvcs=false"

# CNI naming/layout: containerd looks in /opt/cni/bin. go-mod installs the built
# binary under ${bindir}; relocate it to the CNI bin dir and drop the Go source
# tree that go_do_install stages into the -dev package.
do_install:append() {
    install -d ${D}/opt/cni/bin
    if [ -f ${D}${bindir}/wendy-mesh ]; then
        mv ${D}${bindir}/wendy-mesh ${D}/opt/cni/bin/wendy-mesh
        rmdir --ignore-fail-on-non-empty ${D}${bindir}
    else
        bbfatal "wendy-mesh binary not produced by go build"
    fi
}

FILES:${PN} = "/opt/cni/bin/wendy-mesh"

# Only relevant when the container runtime is present.
inherit features_check
REQUIRED_DISTRO_FEATURES = "virtualization"
