# The JP7 kernel builds TPROXY as a module. Install it independently of USB
# gadget support; its generated dependencies bring in the supporting modules.
RDEPENDS:${PN} += "kernel-module-xt-tproxy"
