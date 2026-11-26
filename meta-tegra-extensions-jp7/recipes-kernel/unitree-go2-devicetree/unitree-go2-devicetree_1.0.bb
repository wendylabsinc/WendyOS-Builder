SUMMARY = "Jetson Orin NX device tree for the Unitree Go2 EDU expansion dock"

inherit tegra-devicetree

COMPATIBLE_MACHINE = "^unitree-go2-orin-nx$"

SRC_URI = "file://tegra234-unitree-go2-orin-nx.dts"
DT_FILES = "tegra234-unitree-go2-orin-nx.dts"

# Match the alignment used by the NVIDIA platform DTB recipe.
DT_RESERVED_MAP = "0"
DT_PADDING_SIZE = "0"
