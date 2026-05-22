# RPi defaults: volatile journal logs in tmpfs (no /data partition).
WENDYOS_PERSIST_JOURNAL_LOGS = "0"

# Pin U-Boot to the meta-lts-mixins backport (u-boot_2025.04.bb). The
# poky-scarthgap recipe (u-boot_2024.01.bb) has no BCM2712 support and
# meta-mender-raspberrypi's U-Boot patches are authored against 2025.04
# defconfigs. Without this pin we would rely on PV-comparison alone,
# which silently flips if poky later bumps its bundled U-Boot.
PREFERRED_VERSION_u-boot = "2025.04%"
PREFERRED_VERSION_u-boot-tools = "2025.04%"
