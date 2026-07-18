
SUMMARY = "WendyOS A/B OTA update client"
DESCRIPTION = "Generic A/B over-the-air update client for WendyOS. Installs the \
wendyos-update binary plus the boot-verify and auto-commit systemd units. The \
board-specific behaviour lives behind a connector (tegrauefi for Jetson, \
ubootenv for Raspberry Pi / U-Boot boards); the engine, artifact format and \
CLI are board-agnostic. It is the OTA update client used across WendyOS \
platforms (e.g. JetPack 7 / wrynose)."
HOMEPAGE = "https://github.com/wendylabsinc/wendyos-update"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://src/${GO_IMPORT}/LICENSE;md5=32329fcd0da888dcffa77ba65b409d5e"

GO_IMPORT = "github.com/wendylabsinc/wendyos-update"

# go.bbclass defines GO_SRCURI_DESTSUFFIX on wrynose/blacksail (newer oe-core),
# but scarthgap's go.bbclass does NOT — there go_do_unpack auto-computes the
# destsuffix only when the recipe leaves it unset. Our SRC_URI references
# ${GO_SRCURI_DESTSUFFIX} explicitly, so on scarthgap it expands empty and the
# git clone lands in WORKDIR and fails ("destination path already exists").
# Provide a fallback with the SAME value both code paths compute, so this recipe
# builds on every tree (RPi=scarthgap, Thor=wrynose, Orin=blacksail). ?= defers
# to go.bbclass where it already sets this.
GO_SRCURI_DESTSUFFIX ?= "${@os.path.join(os.path.basename(d.getVar('S')), 'src', d.getVar('GO_IMPORT')) + '/'}"

SRC_URI = "git://${GO_IMPORT};protocol=https;branch=main;destsuffix=${GO_SRCURI_DESTSUFFIX}"
# 2ef50a95 (main): add the grubenv connector (generic x86-64 GRUB-EFI A/B) — the
# third connector, wiring up x86 A/B OTA Phase 2. Jetson
# (tegrauefi) and RPi (ubootenv) are unaffected and each board still selects its
# own connector at runtime.
# 20ec14e (main, wendyos-update#10): drive rootfs A/B on Orin (t234) by switching
# the BOOT CHAIN (nvbootctrl WITHOUT `-t rootfs`) instead of the rootfs-redundancy
# slot, and skip the redundancy preflight on Orin. RootfsRedundancyLevel is
# unarmable from the OS on Orin (flash-time device-tree setting; efivarfs writes
# EINVAL), so the rootfs-redundancy slot switch is a silent no-op there — verified
# on wendyos-test-adrian: the arm boot service exited SUCCESS yet the var stayed
# level 0. The boot chain is coupled to the rootfs slot and needs no such
# variable, so Orin drives it directly. Thor (t264) and unknown SoCs keep the
# rootfs-redundancy + capsule path. Supersedes the f086a3c firmware-capability
# gating (whose armed-redundancy preflight would refuse every Orin OTA). Builds on:
# 33da342c (main, wendyos-update#8): install preflight refuses when tegra rootfs
# A/B redundancy is not armed (RootfsRedundancyLevel UEFI variable missing/zero).
# A device flashed by writing the rootfs straight to NVMe never gets it set, so
# `nvbootctrl -t rootfs set-active-boot-slot` is a silent no-op and every OTA
# rolls back (running slot != target slot). Paired with the boot service in
# tegra-rootfs-redundancy, which arms it. Builds on:
# f0357892 (main, wendyos-update#7): decouple the rootfs slot switch from the
# bootloader capsule on non-Thor SoCs. UEFI capsule-on-disk is only honored on
# Thor (t264); on Orin (t234) the firmware advertises FILE_CAPSULE_DELIVERY but
# silently never processes a staged capsule, so a bootloader-carrying OTA
# no-op'd (slot never switched, reboot into the same OS, ESRT 0, no
# diagnostics). SwapSlot now allowlists tegra264 for the capsule path and falls
# back to the nvbootctrl slot switch on Orin/unknown SoCs (the new rootfs boots
# on the existing bootloader). Builds on:
# b1f3315a (main): install rejects an OTA payload larger than the target A/B
# slot up front (blockdev.DeviceCapacity seek-to-end pre-flight, exit 3, nothing
# written) — the connector-side last line of defense behind the meta-edgeos
# fixed-rootfs-size pin (wendyos-rootfs-size.inc). Builds on:
# 8fb341c0 (PR #2): merges WDY-1775 — ubootenv resolves MBR (rpi3) A/B slots by
# partition number (an OTA rootfs write wipes the ext4 fs label; the partition
# number is the only durable slot identity on MBR). GPT (rpi4/5) unchanged.
# Builds on:
# 61c46bc (PR #5): the boot verifier confirms EVERY healthy boot to the
# firmware (`nvbootctrl -t rootfs mark-boot-successful`, connector.BootConfirmer).
# With rootfs A/B redundancy enabled, Jetson UEFI arms a boot-validation
# watchdog on every boot and resets the SoC ~2 min into userspace unless the
# boot is confirmed; stock L4T confirms from nv_update_verifier.service, which
# this image does not ship. PR #4 confirmed only at commit, so ordinary boots
# still watchdog-rebooted (observed right after "Starting Wendy Agent"),
# burning firmware retries and flip-flopping slots. A boot the firmware
# flagged unhealthy is deliberately NOT confirmed, so pre-userspace failures
# still auto-fall-back. Builds on:
# 627463ef (PR #4): tegrauefi MarkGood confirms the booted slot with
# `nvbootctrl -t rootfs mark-boot-successful` at commit time — the trial-cycle
# confirm half (RPi already disarms its U-Boot trial in MarkGood).
# 8bba71c6: ubootenv refuses a slot swap when /boot is not a mountpoint, so the
# trial arm can no longer silently no-op against a shadow uboot.env on the rootfs
# (pairs with the /boot-by-LABEL + nofail fstab change, WDY-1768).
# 16614b4b: WDY-1742 verify-boot fix (BootIsCompromised checks only the booted
# slot — kills the Orin Nano stale-inactive-slot false-positive, validated
# against the real r39.2 efivar format) + structured per-slot `status` and the
# `switch` verb.
#
# cb2c7b5: Thor capsule OTA fix.
# Capsule staging now survives the agent's sync-less hard reboot.
SRCREV = "cb2c7b5a5ed67c7f3d9d04315e32bdd3902024e9"

inherit go-mod systemd

# Build only the CLI we ship; the module also has internal/* libraries.
GO_INSTALL = "${GO_IMPORT}/cmd/wendyos-update"

# Build offline from the committed vendor/ tree — no module fetching at
# build time (reproducible). buildvcs is auto-off in the .git-less Yocto
# source copy; set explicitly for clarity.
GOBUILDFLAGS:append = " -mod=vendor -buildvcs=false"

# Source tree root inside the recipe workdir (go.bbclass layout).
GO_SRCDIR = "${S}/src/${GO_IMPORT}"

# --- target-only packaging ---
# The native variant (BBCLASSEXTEND below) builds only the binary so the
# image class can run `wendyos-update pack` on the build host; it must not
# carry the systemd units or the nvbootctrl RDEPENDS.
#
# wendyos-update-commit.service is installed but deliberately NOT enabled: it
# is MASKED below (WDY-1742). The fleet-wide model is a MANUAL commit -- a
# pending trial is finalized only by an explicit `wendyos-update commit`, never
# auto-committed on boot. This keeps the OTA solution self-sufficient (the
# safety gate lives in the image, not in the agent) and lets the operator (or
# whatever drives the update) decide when a boot is healthy. Genuine firmware
# fallback is still caught by commit's own running-slot==target-slot check plus
# its platform-verify cascade, so dropping the auto-commit loses no safety.
SYSTEMD_SERVICE:${PN}:class-target = "wendyos-update-verify.service wendyos-update-boot-complete.target"
SYSTEMD_AUTO_ENABLE:${PN}:class-target = "enable"

do_install:append:class-target() {
    # systemd units (shipped in the repo under systemd/)
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${GO_SRCDIR}/systemd/wendyos-update-verify.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${GO_SRCDIR}/systemd/wendyos-update-commit.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${GO_SRCDIR}/systemd/wendyos-update-boot-complete.target ${D}${systemd_system_unitdir}/

    # Mask the auto-commit unit (manual commit model, see the SYSTEMD_SERVICE
    # note above). A /dev/null override in /etc wins over the /lib unit, so it
    # can neither auto-start nor be started by accident until unmasked. The
    # `wendyos-update commit` CLI is unaffected (it is the binary, not the unit).
    install -d ${D}${sysconfdir}/systemd/system
    ln -sf /dev/null ${D}${sysconfdir}/systemd/system/wendyos-update-commit.service

    # config + lifecycle-hook dirs (config.json is optional; auto-detect
    # works without it — see docs/cli-contract.md). Each <phase>.d holds
    # product executables run at that point in the update sequence; empty
    # dirs are a no-op, shipped for discoverability.
    install -d ${D}${sysconfdir}/wendyos-update/pre-install.d
    install -d ${D}${sysconfdir}/wendyos-update/post-install.d
    install -d ${D}${sysconfdir}/wendyos-update/health.d
    install -d ${D}${sysconfdir}/wendyos-update/post-commit.d
    install -d ${D}${sysconfdir}/wendyos-update/on-failure.d
}

# The Go source tree (incl. vendor/) installed by go_do_install lands in the
# -dev package, so the image gets only /usr/bin/wendyos-update + the units.
# systemd.bbclass auto-packages the units listed in SYSTEMD_SERVICE (verify +
# boot-complete); commit.service is NOT in that list (it is masked, not
# enabled), so its unit file and the /etc mask symlink must be shipped here
# explicitly — otherwise do_package fails installed-vs-shipped on the unit.
FILES:${PN}:append:class-target = " \
    ${sysconfdir}/wendyos-update \
    ${systemd_system_unitdir}/wendyos-update-commit.service \
    ${sysconfdir}/systemd/system/wendyos-update-commit.service \
    "

# No board-specific RDEPENDS here: the binary is board-agnostic (the
# connector is selected at runtime), so naming a connector's tools would
# wrongly couple the generic client to one platform. The runtime tools
# each connector shells out to are guaranteed by the platform itself:
#   - Tegra: nvbootctrl is in every image via meta-tegra's
#     MACHINE_EXTRA_RDEPENDS (tegra-redundant-boot -> tegra-redundant-boot-base);
#     capsule staging uses oe4t-set-uefi-OSIndications from
#     setup-nv-boot-control (packagegroup-wendyos-tegra). efivarfs is in-kernel.

# Native variant provides `wendyos-update pack` for image_types_wendy.bbclass.
BBCLASSEXTEND = "native"
