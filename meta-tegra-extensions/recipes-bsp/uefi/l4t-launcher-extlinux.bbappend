
# Override the upstream default which incorrectly uses the /boot/ prefix
UBOOT_EXTLINUX_FDT:jetson-orin-nano-devkit = "tegra234-p3768-0000+p3767-0005-nv-super.dtb"

# AGX Orin DevKit (64GB variant uses P3701-0005 module on P3737-0000 carrier)
UBOOT_EXTLINUX_FDT:jetson-agx-orin-devkit = "tegra234-p3737-0000+p3701-0005-nv.dtb"

# AGX Thor DevKit (P3834-0008 module on P4071-0000 carrier, tegra264).
UBOOT_EXTLINUX_FDT:jetson-agx-thor-devkit = "tegra264-p4071-0000+p3834-0008-nv.dtb"

# Camera DT overlays (L4TLauncher OVERLAYS line). Space-separated .dtbo
# filenames; l4t-extlinux-config.bbclass prepends /boot/ and joins with
# commas. The .dtbo files themselves are copied from the kernel's deployed
# devicetree dir into /boot/ by l4t-launcher-extlinux.bb's do_install — no
# extra recipe needed. Defaults enable RPi-ecosystem ribbon cameras
# (IMX219 + IMX477) on the Orin Nano dual-CSI carrier and dual IMX274 on
# AGX Orin. Override in local.conf to swap sensors, e.g.
#   UBOOT_EXTLINUX_FDTOVERLAYS:jetson-orin-nano-devkit = "tegra234-p3767-camera-p3768-imx477-A.dtbo"
# Thor (tegra264 / JP7) deferred per WDY-1249.
UBOOT_EXTLINUX_FDTOVERLAYS:jetson-orin-nano-devkit = "tegra234-p3767-camera-p3768-imx219-imx477.dtbo"
UBOOT_EXTLINUX_FDTOVERLAYS:jetson-agx-orin-devkit = "tegra234-p3737-camera-dual-imx274-overlay.dtbo"
