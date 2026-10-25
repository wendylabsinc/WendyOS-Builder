FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# rtl8822ce casts a shorter private struct to cfg80211_external_auth_params:
# cfg80211 reads a junk MLD address past it and wpa_supplicant 2.11+ uses it.
SRC_URI += "file://0001-rtl8822ce-pass-cfg80211-its-own-external_auth_params.patch;patchdir=nvidia-oot"

# rtl8822ce never recovers from a TX DMA error: NVIDIA builds it without
# DBG_CONFIG_ERROR_RESET, so its silent reset is empty, and it dumps its TX
# rings to the kernel log every 2 s while the error lasts (WDY-4035).
SRC_URI += " \
    file://0002-rtl8822ce-turn-on-the-driver-s-silent-reset.patch;patchdir=nvidia-oot \
    file://0003-rtl8822ce-log-a-TX-DMA-error-and-dump-the-TX-rings-once.patch;patchdir=nvidia-oot \
"
