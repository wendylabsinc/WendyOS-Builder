# Qualcomm-specific distro configuration, shared by every qcom board.

# Hexagon DSP userspace selection. The signed DSP firmware authorises each Hexagon binary
# by ELF segment hash, so this must name the build the shipped linux-firmware admits.
# hexagon-dsp-binaries carries several; verify a change with its scripts/check.py.
#
# hexagon-dsp-binaries is allarch, so the three pins below must hold one value across all
# qcom machines; overriding any of them per machine gives one sstate object two
# signatures.
WENDYOS_QCOM_DSP_BUILD ?= "DSP.AT.1.0.1-00201-LEMANS-2"

# SoC directories to retarget. Only boards this repo builds, so an upstream change to an
# unused SoC cannot fail the build.
WENDYOS_QCOM_DSP_SOCS ?= "qcs8300"

# The linux-firmware version oe-core ships. A bump must fail the build until the DSP
# build above has been re-checked against it.
WENDYOS_QCOM_DSP_FW_PV ?= "20260622"
