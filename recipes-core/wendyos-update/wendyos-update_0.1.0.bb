
SUMMARY = "WendyOS A/B OTA update client"
DESCRIPTION = "Generic A/B over-the-air update client for WendyOS. Installs the \
wendy-update binary plus the boot-verify and auto-commit systemd units. The \
board-specific behaviour lives behind a connector (tegrauefi for Jetson); the \
engine, artifact format and CLI are board-agnostic. Replaces the Mender client \
on platforms without meta-mender support (e.g. JetPack 7 / wrynose)."
HOMEPAGE = "https://github.com/wendylabsinc/wendy-os-update"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://src/${GO_IMPORT}/LICENSE;md5=32329fcd0da888dcffa77ba65b409d5e"

GO_IMPORT = "github.com/wendylabsinc/wendy-os-update"

SRC_URI = "git://${GO_IMPORT};protocol=https;branch=main;destsuffix=${GO_SRCURI_DESTSUFFIX}"
SRCREV = "205222dcaf5080aa22bd106d0b2a6e4fa6573ad2"

inherit go-mod systemd

# Build only the CLI we ship; the module also has internal/* libraries.
GO_INSTALL = "${GO_IMPORT}/cmd/wendy-update"

# Build offline from the committed vendor/ tree — no module fetching at
# build time (reproducible). buildvcs is auto-off in the .git-less Yocto
# source copy; set explicitly for clarity.
GOBUILDFLAGS:append = " -mod=vendor -buildvcs=false"

# Source tree root inside the recipe workdir (go.bbclass layout).
GO_SRCDIR = "${S}/src/${GO_IMPORT}"

# --- target-only packaging ---
# The native variant (BBCLASSEXTEND below) builds only the binary so the
# image class can run `wendy-update pack` on the build host; it must not
# carry the systemd units or the nvbootctrl RDEPENDS.
SYSTEMD_SERVICE:${PN}:class-target = "wendy-update-verify.service wendy-update-commit.service wendy-update-boot-complete.target"
SYSTEMD_AUTO_ENABLE:${PN}:class-target = "enable"

do_install:append:class-target() {
    # systemd units (shipped in the repo under systemd/)
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${GO_SRCDIR}/systemd/wendy-update-verify.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${GO_SRCDIR}/systemd/wendy-update-commit.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${GO_SRCDIR}/systemd/wendy-update-boot-complete.target ${D}${systemd_system_unitdir}/

    # config + lifecycle-hook dirs (config.json is optional; auto-detect
    # works without it — see docs/cli-contract.md). Each <phase>.d holds
    # product executables run at that point in the update sequence; empty
    # dirs are a no-op, shipped for discoverability.
    install -d ${D}${sysconfdir}/wendy-update/pre-install.d
    install -d ${D}${sysconfdir}/wendy-update/post-install.d
    install -d ${D}${sysconfdir}/wendy-update/health.d
    install -d ${D}${sysconfdir}/wendy-update/post-commit.d
    install -d ${D}${sysconfdir}/wendy-update/on-failure.d
}

# The Go source tree (incl. vendor/) installed by go_do_install lands in the
# -dev package, so the image gets only /usr/bin/wendy-update + the units.
FILES:${PN}:append:class-target = " ${sysconfdir}/wendy-update"

# No board-specific RDEPENDS here: the binary is board-agnostic (the
# connector is selected at runtime), so naming a connector's tools would
# wrongly couple the generic client to one platform. The runtime tools
# each connector shells out to are guaranteed by the platform itself:
#   - Tegra: nvbootctrl is in every image via meta-tegra's
#     MACHINE_EXTRA_RDEPENDS (tegra-redundant-boot -> tegra-redundant-boot-base);
#     capsule staging uses oe4t-set-uefi-OSIndications from
#     setup-nv-boot-control (packagegroup-wendyos-tegra). efivarfs is in-kernel.

# Native variant provides `wendy-update pack` for image_types_wendy.bbclass.
BBCLASSEXTEND = "native"
