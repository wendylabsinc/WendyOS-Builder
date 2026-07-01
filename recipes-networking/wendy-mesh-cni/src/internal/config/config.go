package config

import (
	"encoding/json"
	"fmt"

	"github.com/containernetworking/cni/pkg/types"
	"github.com/containernetworking/cni/pkg/version"
)

const ContractMajorVersion = 1

type MeshArgs struct {
	ContractVersion int    `json:"contractVersion"`
	Enabled         bool   `json:"enabled"`
	ServiceCIDR     string `json:"serviceCIDR"`
	Gateway         string `json:"gateway"`
}

type NetConf struct {
	types.NetConf
	RuntimeConfig struct {
		Mesh MeshArgs `json:"mesh"`
	} `json:"runtimeConfig"`
}

// Parse unmarshals the CNI stdin config and validates the mesh contract.
// An absent runtimeConfig.mesh block parses as a disabled (unmeshed) mesh.
func Parse(stdin []byte) (*NetConf, error) {
	nc := &NetConf{}
	if err := json.Unmarshal(stdin, nc); err != nil {
		return nil, fmt.Errorf("parsing netconf: %w", err)
	}
	// json.Unmarshal fills RawPrevResult but NOT PrevResult; this converts it
	// so cmdAdd's passthrough emits the real chained result. No-op when absent.
	if err := version.ParsePrevResult(&nc.NetConf); err != nil {
		return nil, fmt.Errorf("parsing prevResult: %w", err)
	}
	// Version is only meaningful when the agent actually asked for mesh.
	if nc.RuntimeConfig.Mesh.Enabled &&
		nc.RuntimeConfig.Mesh.ContractVersion != ContractMajorVersion {
		return nil, fmt.Errorf(
			"unsupported mesh contract version %d (plugin supports %d)",
			nc.RuntimeConfig.Mesh.ContractVersion, ContractMajorVersion)
	}
	return nc, nil
}
