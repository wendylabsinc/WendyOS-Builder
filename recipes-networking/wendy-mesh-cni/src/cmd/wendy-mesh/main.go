package main

import (
	"fmt"
	"net"

	"github.com/containernetworking/cni/pkg/skel"
	"github.com/containernetworking/cni/pkg/types"
	current "github.com/containernetworking/cni/pkg/types/100"
	"github.com/containernetworking/cni/pkg/version"

	"github.com/wendylabsinc/wendyos-builder/wendy-mesh-cni/internal/config"
	"github.com/wendylabsinc/wendyos-builder/wendy-mesh-cni/internal/mesh"
)

// containerIPFromPrev returns the first IPv4 address the previous plugin assigned.
func containerIPFromPrev(nc *config.NetConf) (net.IP, *current.Result, error) {
	if nc.PrevResult == nil {
		return nil, nil, fmt.Errorf("no prevResult: wendy-mesh must be chained after a plugin that provides one")
	}
	res, err := current.NewResultFromResult(nc.PrevResult)
	if err != nil {
		return nil, nil, fmt.Errorf("parsing prevResult: %w", err)
	}
	for _, ipc := range res.IPs {
		if ip := ipc.Address.IP.To4(); ip != nil {
			return ip, res, nil
		}
	}
	return nil, res, fmt.Errorf("no IPv4 address in prevResult")
}

func cmdAdd(args *skel.CmdArgs) error {
	nc, err := config.Parse(args.StdinData)
	if err != nil {
		return err
	}
	// Unmeshed: strict passthrough. Never touch the host, never error.
	if !nc.RuntimeConfig.Mesh.Enabled {
		return types.PrintResult(nc.PrevResult, nc.CNIVersion)
	}
	ip, res, err := containerIPFromPrev(nc)
	if err != nil {
		return err // meshed containers fail closed
	}
	if err := mesh.Add(args.Netns, ip, nc.RuntimeConfig.Mesh); err != nil {
		return err // fail closed
	}
	return types.PrintResult(res, nc.CNIVersion)
}

func cmdDel(args *skel.CmdArgs) error {
	nc, err := config.Parse(args.StdinData)
	if err != nil {
		return err
	}
	if !nc.RuntimeConfig.Mesh.Enabled {
		return nil
	}
	ip, _, err := containerIPFromPrev(nc)
	if err != nil {
		// On DEL the prevResult may be absent; nothing to tear down per-IP.
		return nil
	}
	return mesh.Del(ip, nc.RuntimeConfig.Mesh)
}

func cmdCheck(args *skel.CmdArgs) error {
	nc, err := config.Parse(args.StdinData)
	if err != nil {
		return err
	}
	if !nc.RuntimeConfig.Mesh.Enabled {
		return nil
	}
	ip, _, err := containerIPFromPrev(nc)
	if err != nil {
		return err
	}
	return mesh.Check(args.Netns, ip, nc.RuntimeConfig.Mesh)
}

func main() {
	skel.PluginMainFuncs(
		skel.CNIFuncs{Add: cmdAdd, Del: cmdDel, Check: cmdCheck},
		version.PluginSupports("0.4.0", "1.0.0"),
		"wendy-mesh CNI plugin",
	)
}
