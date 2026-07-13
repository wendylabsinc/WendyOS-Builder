# RPi defaults: volatile journal logs in tmpfs (no /data partition).
WENDYOS_PERSIST_JOURNAL_LOGS = "0"

# UNPACKDIR shim for the scarthgap tree. UNPACKDIR (the per-recipe sources unpack
# dir) was added to oe-core AFTER scarthgap -- it is native on blacksail
# (UNPACKDIR ??= "${WORKDIR}/sources") but UNDEFINED on scarthgap. Several recipes
# reference ${UNPACKDIR} in S / do_install (grow-data-part, wendyos-fw-env,
# rpi-eeprom-config, expand-rootfs-rpi, first-boot-timesync, wendyos-update-config,
# ...); on scarthgap those expand empty and do_install fails ("cannot stat
# /<file>"). scarthgap unpacks sources straight into WORKDIR, so point UNPACKDIR
# there. Build-level, so it covers every recipe in a scarthgap RPi build, not just
# meta-rpi-extensions. This file is scarthgap-only (blacksail boards use
# rpi-blacksail.inc), and ??= is inert where UNPACKDIR is already defined.
UNPACKDIR ??= "${WORKDIR}"

# Pin U-Boot to the meta-lts-mixins backport (u-boot_2025.04.bb). The
# poky-scarthgap recipe (u-boot_2024.01.bb) has no BCM2712 support and the
# RPi U-Boot patches are authored against 2025.04
# defconfigs. Without this pin we would rely on PV-comparison alone,
# which silently flips if poky later bumps its bundled U-Boot.
PREFERRED_VERSION_u-boot = "2025.04%"
PREFERRED_VERSION_u-boot-tools = "2025.04%"
