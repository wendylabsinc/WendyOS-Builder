package mesh

import "net"

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
