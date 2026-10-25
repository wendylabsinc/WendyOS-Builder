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
