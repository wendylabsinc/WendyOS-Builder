
# WendyOS x86: enable systemd's TPM2 + cryptsetup support for the /data
# encryption stack. tpm2 pulls in libtss2
# (from meta-tpm) so systemd-cryptenroll can seal a LUKS2 keyslot to the TPM.
# cryptsetup enables systemd-cryptsetup and the LUKS2 TPM2 token consumed at boot.
#
# This bbappend lives in meta-x86-extensions (layered only for the x86 board, see
# conf/template/include/bblayers/x86.inc), so it never affects other targets and
# keeps the TPM experiment isolated. The :x86-wendyos override is belt-and-braces
# to the same effect. Gated on WENDYOS_ENABLE_TPM so an x86 build with the TPM stack
# off gets stock systemd (no libtss2/cryptsetup dependency pulled in).
PACKAGECONFIG:append:x86-wendyos = "${@' tpm2 cryptsetup' if d.getVar('WENDYOS_ENABLE_TPM') == '1' else ''}"
