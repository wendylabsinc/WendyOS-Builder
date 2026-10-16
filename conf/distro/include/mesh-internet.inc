# Shared by kernel configuration, module packaging and the final rootfs gate.
WENDYOS_MESH_INTERNET_BUILTIN = ""
WENDYOS_MESH_INTERNET_MODULES = " \
    CONFIG_IPV6_TUNNEL:ip6_tunnel \
    CONFIG_INET6_TUNNEL:tunnel6 \
    CONFIG_NF_CONNTRACK:nf_conntrack \
    CONFIG_NF_CT_NETLINK:nf_conntrack_netlink \
    CONFIG_NF_NAT:nf_nat \
    CONFIG_IP6_NF_IPTABLES:ip6_tables \
    CONFIG_IP6_NF_FILTER:ip6table_filter \
    CONFIG_IP6_NF_NAT:ip6table_nat \
    CONFIG_IP6_NF_TARGET_REJECT:ip6t_REJECT \
    CONFIG_NETFILTER_XT_MATCH_COMMENT:xt_comment \
    CONFIG_IP_NF_MANGLE:iptable_mangle \
    CONFIG_IP6_NF_MANGLE:ip6table_mangle \
    CONFIG_NETFILTER_XT_TARGET_TCPMSS:xt_TCPMSS \
    CONFIG_NETFILTER_XT_MATCH_CONNTRACK:xt_conntrack \
    CONFIG_NETFILTER_XT_TARGET_MASQUERADE:xt_MASQUERADE \
    "
