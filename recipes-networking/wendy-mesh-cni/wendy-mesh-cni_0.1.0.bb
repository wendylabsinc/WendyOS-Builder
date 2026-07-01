SUMMARY = "wendy-mesh chained CNI plugin"
DESCRIPTION = "Stateless CNI plugin that routes a meshed container's egress to \
the mesh service CIDR. Chained after bridge+portmap; driven entirely by the \
agent via a versioned CNI runtimeConfig contract."
LICENSE = "MIT"
# NOTE: this md5 was computed directly from the committed src/LICENSE (it
# carries a copyright line, so it differs from the bare MIT template hash in
# COMMON_LICENSE_DIR/MIT). Computed with:
#   md5 recipes-networking/wendy-mesh-cni/src/LICENSE
# LIC_FILES_CHKSUM paths are resolved relative to ${S} (license.bbclass
# find_license_files() uses d.getVar('S') as srcdir), and LICENSE is staged
# at ${S}/src/${GO_IMPORT}/LICENSE (see the SRC_URI note below) -- NOT at
# ${S}/src/LICENSE -- so the path here must include ${GO_IMPORT}.
LIC_FILES_CHKSUM = "file://src/${GO_IMPORT}/LICENSE;md5=382861ee89f2ea998f59ae5411c3ce3d"

# In-repo Go source (committed under src/, incl. vendor/). Built offline.
GO_IMPORT = "github.com/wendylabsinc/wendyos-builder/wendy-mesh-cni"

FILESEXTRAPATHS:prepend := "${THISDIR}:"

# --- SRC_URI layout note (read before touching subdir=/S/GO_SRCDIR) ---
# BitBake's local (file://) fetcher unpacks via a plain recursive copy
# (bb.fetch2.FetchMethod.unpack -> generic fetch2 unpack: `cp -fpPRH "<src>"
# "<destdir>"`, run with cwd=<subdir-or-rootdir>). cp -R preserves the
# *basename of the source path*, it does not dump the source's contents
# into destdir. So a single-entry SRC_URI naming the whole "src" directory,
# e.g. `file://src;subdir=X`, always lands the tree at
# ${WORKDIR}/X/src/... -- an extra "src" segment is unavoidably re-added.
# That extra segment is exactly what broke this recipe before: the old
# `SRC_URI = "file://src;subdir=${BP}/src/${GO_IMPORT}"` landed the tree one
# level *deeper* than declared, at .../${GO_IMPORT}/src/{go.mod,LICENSE,...},
# while S/GO_SRCDIR/LIC_FILES_CHKSUM all pointed one directory short of that.
#
# go.bbclass requires the module root at ${S}/src/${GO_IMPORT} (GOPATH-style:
# go_do_configure does `ln -snf ${S}/src ${B}/`; go-mod.bbclass runs
# do_compile with cwd ${B}/src/${GO_WORKDIR} == ${B}/src/${GO_IMPORT}, which
# resolves through that symlink to ${S}/src/${GO_IMPORT} -- exactly where
# go.mod must sit; go_do_install also hardcodes `${S}/src/${GO_IMPORT}` as
# its tar source). That path structure is not overridable without patching
# go.bbclass, so S must supply it.
#
# To land go.mod etc. directly at ${S}/src/${GO_IMPORT} (not one level
# nested under a redundant "src") without renaming the on-disk src/
# directory (recipes-networking/wendy-mesh-cni/src/ must stay put --
# .superpowers/sdd/run-tests.sh and go-c.sh hardcode that path), we fetch
# src/'s children individually. Each child keeps ITS OWN basename (cmd,
# go.mod, go.sum, internal, LICENSE, vendor), so cp -R drops each one
# directly into subdir= with no extra wrapper directory:
#   file://src/cmd;subdir=${BP}/src/${GO_IMPORT}       -> .../${GO_IMPORT}/cmd
#   file://src/go.mod;subdir=${BP}/src/${GO_IMPORT}    -> .../${GO_IMPORT}/go.mod
#   ... (go.sum, internal, LICENSE, vendor likewise)
# giving exactly ${WORKDIR}/${BP}/src/${GO_IMPORT}/{cmd,go.mod,go.sum,
# internal,LICENSE,vendor} == ${S}/src/${GO_IMPORT}/... once S = ${WORKDIR}/${BP}
# (the bitbake.conf default, unchanged here). Verified by hand-copying with
# the same `cp -fpPRH` invocation fetch2 uses -- see task report.
SRC_URI = "\
    file://src/cmd;subdir=${BP}/src/${GO_IMPORT} \
    file://src/go.mod;subdir=${BP}/src/${GO_IMPORT} \
    file://src/go.sum;subdir=${BP}/src/${GO_IMPORT} \
    file://src/internal;subdir=${BP}/src/${GO_IMPORT} \
    file://src/LICENSE;subdir=${BP}/src/${GO_IMPORT} \
    file://src/vendor;subdir=${BP}/src/${GO_IMPORT} \
    "

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
