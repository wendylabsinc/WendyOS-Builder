package mesh

import (
	"fmt"
	"net"
	"reflect"
	"testing"

	"github.com/containernetworking/plugins/pkg/ns"
	"github.com/containernetworking/plugins/pkg/testutils"
	"github.com/coreos/go-iptables/iptables"
	"github.com/vishvananda/netlink"
	"github.com/wendylabsinc/wendyos-builder/wendy-mesh-cni/internal/config"
)

func TestRuleSpecScopedToContainerIP(t *testing.T) {
	got := ruleSpec(net.ParseIP("10.88.0.7"), "10.99.0.0/16")
	want := []string{
		"-s", "10.88.0.7/32",
		"-d", "10.99.0.0/16",
		"-j", "ACCEPT",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ruleSpec = %v, want %v", got, want)
	}
}

// meshAddFixture builds the preconditions a real CNI invocation of mesh.Add
// always has by the time it runs: a container netns with a connected route
// (so the kernel can resolve the gateway) and a pre-existing WENDY-MESH host
// chain (which the agent, not this plugin, creates in production). It
// returns the netns and an iptables handle, and registers cleanup via
// t.Cleanup so callers don't have to.
func meshAddFixture(t *testing.T) (ns.NetNS, *iptables.IPTables) {
	t.Helper()
	if _, err := netlink.LinkList(); err != nil {
		t.Skip("needs CAP_NET_ADMIN")
	}
	targetNS, err := testutils.NewNS()
	if err != nil {
		t.Fatalf("NewNS: %v", err)
	}
	t.Cleanup(func() { testutils.UnmountNS(targetNS) })

	// Real CNI invocations always run mesh.Add after the preceding plugin
	// (e.g. bridge) has already wired the container's veth with an address
	// in the gateway's subnet - the route install's kernel-side gateway
	// resolution depends on that connected route existing. testutils.NewNS()
	// hands back a bare namespace with only a down loopback, so give it the
	// same connected route a real container netns would already have before
	// this plugin runs.
	err = targetNS.Do(func(ns.NetNS) error {
		la := netlink.NewLinkAttrs()
		la.Name = "dummy0"
		dummy := &netlink.Dummy{LinkAttrs: la}
		if err := netlink.LinkAdd(dummy); err != nil {
			return fmt.Errorf("adding dummy0: %w", err)
		}
		addr, err := netlink.ParseAddr("10.88.0.7/24")
		if err != nil {
			return err
		}
		if err := netlink.AddrAdd(dummy, addr); err != nil {
			return fmt.Errorf("adding addr to dummy0: %w", err)
		}
		return netlink.LinkSetUp(dummy)
	})
	if err != nil {
		t.Fatalf("prep netns link: %v", err)
	}

	// In production the agent pre-creates the WENDY-MESH chain and jumps to
	// it from FORWARD before any plugin invocation; Add only ever
	// appends/removes rules inside it. Recreate that host-side precondition
	// here and clean up afterward so the test is idempotent.
	ipt, err := iptables.NewWithProtocol(iptables.ProtocolIPv4)
	if err != nil {
		t.Fatalf("iptables init: %v", err)
	}
	if err := ipt.NewChain(iptTable, meshChain); err != nil {
		t.Fatalf("creating %s chain: %v", meshChain, err)
	}
	t.Cleanup(func() {
		if err := ipt.ClearAndDeleteChain(iptTable, meshChain); err != nil {
			t.Logf("cleanup: deleting %s chain: %v", meshChain, err)
		}
	})

	return targetNS, ipt
}

func TestAddInstallsRouteInNetns(t *testing.T) {
	targetNS, ipt := meshAddFixture(t)

	containerIP := net.ParseIP("10.88.0.7")
	args := config.MeshArgs{
		Enabled: true, ServiceCIDR: "10.99.0.0/16", Gateway: "10.88.0.1",
	}
	if err := Add(targetNS.Path(), containerIP, args); err != nil {
		t.Fatalf("Add: %v", err)
	}

	err := targetNS.Do(func(ns.NetNS) error {
		routes, err := netlink.RouteList(nil, netlink.FAMILY_V4)
		if err != nil {
			return err
		}
		for _, r := range routes {
			if r.Dst != nil && r.Dst.String() == "10.99.0.0/16" {
				return nil
			}
		}
		t.Fatal("service CIDR route not found in netns")
		return nil
	})
	if err != nil {
		t.Fatalf("inspect netns: %v", err)
	}

	// Close the contract: Add's host-side effect (the iptables ACCEPT rule)
	// must have landed too, not just the netns route.
	exists, err := ipt.Exists(iptTable, meshChain, ruleSpec(containerIP, args.ServiceCIDR)...)
	if err != nil {
		t.Fatalf("checking mesh accept rule: %v", err)
	}
	if !exists {
		t.Fatal("mesh accept rule not found in WENDY-MESH chain")
	}
}

// TestAddIsIdempotent guards against a regression where a retried CNI ADD
// against the same netns (same container IP, same args) fails because the
// underlying route install is not idempotent (e.g. RouteAdd returning
// EEXIST on the second call). CNI runtimes are expected to retry ADD, so
// Add must tolerate being called twice with identical arguments.
func TestAddIsIdempotent(t *testing.T) {
	targetNS, _ := meshAddFixture(t)

	containerIP := net.ParseIP("10.88.0.7")
	args := config.MeshArgs{
		Enabled: true, ServiceCIDR: "10.99.0.0/16", Gateway: "10.88.0.1",
	}
	if err := Add(targetNS.Path(), containerIP, args); err != nil {
		t.Fatalf("first Add: %v", err)
	}
	if err := Add(targetNS.Path(), containerIP, args); err != nil {
		t.Fatalf("second Add (retry) should be idempotent, got error: %v", err)
	}
}

func TestDelIsIdempotent(t *testing.T) {
	if _, err := netlink.LinkList(); err != nil {
		t.Skip("needs CAP_NET_ADMIN")
	}
	args := config.MeshArgs{Enabled: true, ServiceCIDR: "10.99.0.0/16", Gateway: "10.88.0.1"}
	ip := net.ParseIP("10.88.0.9")
	// Del with nothing installed must not error.
	if err := Del(ip, args); err != nil {
		t.Fatalf("first Del errored: %v", err)
	}
	// Del again must also not error.
	if err := Del(ip, args); err != nil {
		t.Fatalf("second Del errored: %v", err)
	}
}
