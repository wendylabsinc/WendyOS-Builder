package mesh

import (
	"fmt"
	"net"

	"github.com/containernetworking/plugins/pkg/ns"
	"github.com/coreos/go-iptables/iptables"
	"github.com/vishvananda/netlink"

	"github.com/wendylabsinc/wendyos-builder/wendy-mesh-cni/internal/config"
)

// meshChain is the iptables filter chain the agent pre-creates and jumps to
// from FORWARD. The plugin only adds/removes per-container ACCEPT rules in it,
// so a plugin bug can never open traffic the agent did not intend.
const (
	iptTable  = "filter"
	meshChain = "WENDY-MESH"
)

// ruleSpec returns the iptables rule (sans -A/-D verb) permitting exactly this
// container's IP to egress toward the mesh service CIDR. Shared by Add, Del and
// Check so the three can never drift.
func ruleSpec(containerIP net.IP, serviceCIDR string) []string {
	return []string{
		"-s", containerIP.String() + "/32",
		"-d", serviceCIDR,
		"-j", "ACCEPT",
	}
}

// Add programs mesh egress for one meshed container: a scoped route inside the
// container netns and a host iptables ACCEPT rule keyed to the container IP.
func Add(netns string, containerIP net.IP, a config.MeshArgs) error {
	_, dst, err := net.ParseCIDR(a.ServiceCIDR)
	if err != nil {
		return fmt.Errorf("parsing serviceCIDR %q: %w", a.ServiceCIDR, err)
	}
	gw := net.ParseIP(a.Gateway)
	if gw == nil {
		return fmt.Errorf("parsing gateway %q", a.Gateway)
	}

	// Route inside the container's network namespace. RouteReplace (not
	// RouteAdd) so a retried CNI ADD against the same netns is idempotent
	// instead of failing with EEXIST.
	if err := ns.WithNetNSPath(netns, func(ns.NetNS) error {
		return netlink.RouteReplace(&netlink.Route{Dst: dst, Gw: gw})
	}); err != nil {
		return fmt.Errorf("installing netns route: %w", err)
	}

	// Host filter rule (idempotent AppendUnique) scoped to this container IP.
	ipt, err := iptables.NewWithProtocol(iptables.ProtocolIPv4)
	if err != nil {
		return fmt.Errorf("iptables init: %w", err)
	}
	if err := ipt.AppendUnique(iptTable, meshChain, ruleSpec(containerIP, a.ServiceCIDR)...); err != nil {
		return fmt.Errorf("adding mesh accept rule: %w", err)
	}
	return nil
}

// Check verifies the host rule exists for this container IP. (The netns route
// is best-effort; the host rule is the authoritative, inspectable artifact.)
func Check(netns string, containerIP net.IP, a config.MeshArgs) error {
	ipt, err := iptables.NewWithProtocol(iptables.ProtocolIPv4)
	if err != nil {
		return fmt.Errorf("iptables init: %w", err)
	}
	ok, err := ipt.Exists(iptTable, meshChain, ruleSpec(containerIP, a.ServiceCIDR)...)
	if err != nil {
		return fmt.Errorf("checking mesh rule: %w", err)
	}
	if !ok {
		return fmt.Errorf("mesh accept rule missing for %s", containerIP)
	}
	return nil
}

// Del removes the host rule for this container IP. The netns route is torn down
// automatically when the namespace is destroyed, so Del only touches the host.
// Idempotent: a missing rule (or missing chain) is not an error.
func Del(containerIP net.IP, a config.MeshArgs) error {
	ipt, err := iptables.NewWithProtocol(iptables.ProtocolIPv4)
	if err != nil {
		return fmt.Errorf("iptables init: %w", err)
	}
	err = ipt.DeleteIfExists(iptTable, meshChain, ruleSpec(containerIP, a.ServiceCIDR)...)
	if err != nil {
		return fmt.Errorf("deleting mesh accept rule: %w", err)
	}
	return nil
}
