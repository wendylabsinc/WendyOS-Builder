# Driver add-ons: the kernel side. Required from linux-raspberrypi_%.bbappend when
# WENDYOS_DRIVER_EXTENSIONS == "1", so nothing here needs its own gate. The .cfg files
# resolve through the FILESEXTRAPATHS the bbappend already prepends.

# The filesystems the merge path needs, plus module signing. Both are one-time kernel
# changes; adding a driver never comes back here.
SRC_URI:append:rpi = " file://sysext.cfg file://module-sign.cfg"

# Module signing key. Unset (dev): the kernel mints a throwaway key per build, so an
# externally-signed .ko won't verify — harmless while MODULE_SIG_FORCE is off. Set (CI):
# a stable PEM, whose certificate is baked into .builtin_trusted_keys so the driver
# pipeline's signatures are the ones this kernel trusts.
WENDYOS_MODULE_SIGN_KEY ?= ""

# Attached only where add-ons are enabled, which is what the require gating this file
# already decides. A :prepend is inlined into the task body, so an unconditional one
# would change do_configure's taskhash — and force a kernel rebuild — on every RPi
# machine, including those where the function does nothing.
python __anonymous() {
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
