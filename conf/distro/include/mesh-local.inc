# Local mesh is an IPv6 routed underlay even when container applications use
# IPv4 VIPs. Keep the resolved kernel and installed-module contracts together.
WENDYOS_MESH_LOCAL_BUILTIN = " \
    CONFIG_IP_ADVANCED_ROUTER \
    CONFIG_IP_MULTIPLE_TABLES \
    CONFIG_IPV6_MULTIPLE_TABLES \
    "

# Symbol:kernel_module_name. Built-ins need no package; modular features must
# have their module and dependencies in the image, not merely in the devkit.
WENDYOS_MESH_LOCAL_MODULES = " \
    CONFIG_DUMMY:dummy \
    CONFIG_IPV6:ipv6 \
    CONFIG_TUN:tun \
    CONFIG_NETFILTER_XT_TARGET_TPROXY:xt_TPROXY \
    CONFIG_NF_TPROXY_IPV4:nf_tproxy_ipv4 \
    "

# Image checks read the kernel's cached outputs, never its build tree: that has
# no sstate, so depending on it recompiles the kernel for every image.
# recipes-kernel/linux/mesh-local.inc deploys the config.
WENDYOS_KERNEL_CONFIG = "${DEPLOY_DIR_IMAGE}/wendyos-mesh-local-${MACHINE}.config"
WENDYOS_KERNEL_RELEASE_FILE = "${PKGDATA_DIR}/kernel-depmod/kernel-abiversion"
WENDYOS_KERNEL_OUTPUTS_DEPENDS = "virtual/kernel:do_deploy virtual/kernel:do_packagedata"
