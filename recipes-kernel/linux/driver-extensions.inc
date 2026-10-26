# Driver add-ons: the kernel side. Required from a board's kernel bbappend when
# WENDYOS_DRIVER_EXTENSIONS == "1", so nothing here needs its own gate — and no
# machine override either, since only a board that requires this file gets it.
#
# Board-neutral on purpose: the fragments below name no arch and no machine, and
# the signing prefunc only touches kbuild's own CONFIG_MODULE_SIG_KEY. Wiring a
# new board is the one gated require in its kernel bbappend, nothing here.

# Bring the fragments along, so a board's bbappend does not have to know where they
# live. ${THISDIR} is this file's directory during its own parse, not the including
# bbappend's, so the path stays right however it is required.
FILESEXTRAPATHS:prepend := "${THISDIR}/driver-extensions:"

# The filesystems the merge path needs, plus module signing. Both are one-time kernel
# changes; adding a driver never comes back here.
SRC_URI += " \
    file://sysext.cfg \
    file://module-sign.cfg \
    "

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
    if d.getVar('WENDYOS_DRIVER_DEVKIT_MODULES'):
        d.appendVarFlag('do_compile_kernelmodules', 'postfuncs', ' wendyos_export_driver_modules')
    key = d.getVar('WENDYOS_MODULE_SIGN_KEY')
    if key:
        # Hash the key's contents, not just its path. Secrets are normally rotated in
        # place, and without this the kernel would restore from sstate still trusting the
        # old certificate while the pipeline signs with the new one.
        d.appendVarFlag('do_configure', 'file-checksums', ' %s:True' % key)
}

# Export in-tree modules, stopping at dependencies guaranteed by the base image.
# The devkit packages these exact binaries instead of rebuilding a wireless stack
# against a different source tree. This task runs after shared_workdir and modules.
python wendyos_export_driver_modules() {
    import hashlib
    import json
    from pathlib import Path
    import shutil
    import subprocess

    build = Path(d.getVar('B'))
    dest = Path(d.getVar('STAGING_KERNEL_BUILDDIR')) / 'wendyos-driver-modules'
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    modinfo = str(Path(d.getVar('RECIPE_SYSROOT_NATIVE')) / 'sbin/modinfo')
    available = {}
    for relative in (build / 'modules.order').read_text().splitlines():
        path = build / Path(relative).with_suffix('.ko')
        available.setdefault(path.stem.replace('-', '_'), []).append(path)
    exported = {}
    base_modules = set((d.getVar('WENDYOS_DRIVER_BASE_MODULES') or '').replace('-', '_').split())
    requested = d.getVar('WENDYOS_DRIVER_DEVKIT_MODULES').replace('-', '_').split()
    if base_modules.intersection(requested):
        bb.fatal('Driver devkit: requested add-on modules also belong to the base image')

    def export(name):
        name = name.replace('-', '_')
        if name in exported:
            return
        if name in base_modules:
            exported[name] = {'provided_by': 'base-image'}
            return
        paths = available.get(name, [])
        if len(paths) != 1 or not paths[0].is_file():
            bb.fatal('Driver devkit: expected one built module for %s, got %s' % (name, paths))
        path = paths[0]
        deps = subprocess.check_output([modinfo, '-F', 'depends', str(path)], text=True).strip()
        dependencies = [dep.replace('-', '_') for dep in deps.split(',') if dep]
        shutil.copy2(path, dest / path.name)
        exported[name] = {'file': path.name, 'depends': dependencies,
                          'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        for dependency in dependencies:
            export(dependency)

    for name in requested:
        export(name)
    (dest / 'index.json').write_text(json.dumps(exported, indent=2) + '\n')
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
