SUMMARY = "Device tree for the G1 EDU PC2 Orin NX carrier"

inherit tegra-devicetree

COMPATIBLE_MACHINE = "^unitree-g1-pc2-orin-nx$"
SRC_URI = "file://tegra234-unitree-g1-pc2-orin-nx.dts"
DT_FILES = "tegra234-unitree-g1-pc2-orin-nx.dts"
DT_RESERVED_MAP = "0"
DT_PADDING_SIZE = "0"
