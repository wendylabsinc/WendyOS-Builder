FILESEXTRAPATHS:prepend := "${THISDIR}/linux-raspberrypi:"

# Add container support kernel config when WENDYOS_CONTAINER_RUNTIME is enabled
SRC_URI:append:rpi = "${@' file://container.cfg' if d.getVar('WENDYOS_CONTAINER_RUNTIME') == '1' else ''}"

# Add USB gadget kernel config when WENDYOS_USB_GADGET is enabled
SRC_URI:append:rpi = "${@' file://usb-gadget.cfg' if d.getVar('WENDYOS_USB_GADGET') == '1' else ''}"
SRC_URI += "file://0001-dwc2-force-g_dma-false-for-BCM2712-in-peripheral-mod.patch"

# Driver add-ons: the filesystems the merge path needs, plus module signing. Both are
# one-time kernel changes; adding a driver never comes back here.
SRC_URI:append:rpi = "${@' file://sysext.cfg file://module-sign.cfg' if d.getVar('WENDYOS_DRIVER_EXTENSIONS') == '1' else ''}"

# Module signing key. Unset (dev): the kernel mints a throwaway key per build, so an
# externally-signed .ko won't verify — harmless while MODULE_SIG_FORCE is off. Set (CI):
# a stable PEM, whose certificate is baked into .builtin_trusted_keys so the driver
# pipeline's signatures are the ones this kernel trusts.
WENDYOS_MODULE_SIGN_KEY ?= ""

# Attached only where add-ons are enabled. A :prepend is inlined into the task body, so an
# unconditional one would change do_configure's taskhash — and force a kernel rebuild — on
# every RPi machine, including those where the function does nothing.
python __anonymous() {
    if d.getVar('WENDYOS_DRIVER_EXTENSIONS') != '1':
        return
    d.appendVarFlag('do_configure', 'prefuncs', ' wendyos_install_module_sign_key')
    key = d.getVar('WENDYOS_MODULE_SIGN_KEY')
    if key:
        # Hash the key's contents, not just its path. Secrets are normally rotated in
        # place, and without this the kernel would restore from sstate still trusting the
        # old certificate while the pipeline signs with the new one.
        d.appendVarFlag('do_configure', 'file-checksums', ' %s:True' % key)
}

wendyos_install_module_sign_key() {
    if [ -z "${WENDYOS_MODULE_SIGN_KEY}" ]; then
        # .config survives between builds, so a tree that once had a key would keep
        # pointing at one no longer installed.
        rm -f "${B}/certs/wendyos_signing_key.pem"
        sed -i -e 's|^CONFIG_MODULE_SIG_KEY=.*|CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"|' \
            "${B}/.config" 2>/dev/null || :
        return
    fi

    # Without module signing there is no CONFIG_MODULE_SIG_KEY to redirect, so the sed
    # below would match nothing and leave the key installed but ignored, making every
    # add-on signed with it untrusted by the shipped kernel.
    if ! grep -q '^CONFIG_MODULE_SIG_KEY=' "${B}/.config"; then
        bbfatal "WENDYOS_MODULE_SIGN_KEY is set but this kernel does not sign modules; \
enable WENDYOS_DRIVER_EXTENSIONS for ${MACHINE} or leave the key unset"
    fi

    install -D -m 0600 "${WENDYOS_MODULE_SIGN_KEY}" "${B}/certs/wendyos_signing_key.pem"
    # An earlier build's auto-generated key would otherwise be staged into the shared
    # workdir, leaving a private key there that does not match the trusted certificate.
    rm -f "${B}/certs/signing_key.pem"
    # kbuild's generator is gated on CONFIG_MODULE_SIG_KEY being exactly
    # "certs/signing_key.pem", so a different filename disables it. Relative, not
    # ${B}-absolute: .config ships as /boot/config-* and a TMPDIR path fails buildpaths QA.
    sed -i -e 's|^CONFIG_MODULE_SIG_KEY=.*|CONFIG_MODULE_SIG_KEY="certs/wendyos_signing_key.pem"|' \
        "${B}/.config"
}

# CVE backports below are 6.6.y stable backports — they apply to (and are only
# needed on) the 6.6 kernel that the scarthgap meta-raspberrypi ships. Newer
# kernels already carry these fixes upstream and the 6.6-context patches do NOT
# apply (e.g. blacksail's meta-raspberrypi defaults to 6.12, where the
# crypto/algif_aead series fails do_patch). Gate on the kernel major.minor so
# the same bbappend works on both trees.
#   NOTE: this assumes the CVEs are already fixed in the newer kernel (true for
#   these 6.6.y stable backports vs the 6.12.y LTS). If a future kernel is NOT
#   yet patched, ship a matching backport under its own gate.
WENDYOS_RPI_KERNEL_66 = "${@'1' if (d.getVar('PV') or '').startswith('6.6.') else '0'}"

# CVE-2026-46333 (ssh-keysign-pwn).
SRC_URI:append = "${@' file://cve-2026-46333-ptrace.patch' if d.getVar('WENDYOS_RPI_KERNEL_66') == '1' else ''}"

# CVE-2026-31431 (crypto/algif_aead AAD in-place corruption) — 6.6.y series.
WENDYOS_RPI_CVE_31431 = " \
    file://0001-crypto-scatterwalk-Backport-memcpy_sglist.patch \
    file://0002-crypto-algif_aead-use-memcpy_sglist-instead-of-null-skcipher.patch \
    file://0003-crypto-algif_aead-Revert-to-operating-out-of-place-CVE-2026-31431.patch \
    file://0004-crypto-algif_aead-snapshot-IV-for-async-AEAD-requests.patch \
    file://0005-crypto-algif_aead-Fix-minimum-RX-size-check-for-decryption.patch \
    "

SRC_URI:append = "${@' ' + d.getVar('WENDYOS_RPI_CVE_31431') if d.getVar('WENDYOS_RPI_KERNEL_66') == '1' else ''}"

