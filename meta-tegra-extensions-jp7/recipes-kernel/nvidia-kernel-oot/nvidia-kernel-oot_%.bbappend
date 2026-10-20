# rtl8822ce casts a shorter private struct to cfg80211_external_auth_params:
# cfg80211 reads a junk MLD address past it and wpa_supplicant 2.11+ uses it.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
SRC_URI += "file://0001-rtl8822ce-pass-cfg80211-its-own-external_auth_params.patch;patchdir=nvidia-oot"
