package config

import "testing"

func TestParseMeshedConfig(t *testing.T) {
	stdin := []byte(`{
		"cniVersion":"1.0.0","name":"bridge","type":"wendy-mesh",
		"runtimeConfig":{"mesh":{"contractVersion":1,"enabled":true,
			"serviceCIDR":"10.99.0.0/16","gateway":"10.88.0.1"}},
		"prevResult":{"cniVersion":"1.0.0","interfaces":[],"ips":[]}
	}`)
	nc, err := Parse(stdin)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !nc.RuntimeConfig.Mesh.Enabled {
		t.Fatal("expected mesh enabled")
	}
	if nc.RuntimeConfig.Mesh.ServiceCIDR != "10.99.0.0/16" {
		t.Fatalf("bad serviceCIDR: %q", nc.RuntimeConfig.Mesh.ServiceCIDR)
	}
}

func TestParseRejectsUnknownContractVersion(t *testing.T) {
	stdin := []byte(`{"cniVersion":"1.0.0","name":"bridge","type":"wendy-mesh",
		"runtimeConfig":{"mesh":{"contractVersion":99,"enabled":true,
		"serviceCIDR":"10.99.0.0/16","gateway":"10.88.0.1"}}}`)
	if _, err := Parse(stdin); err == nil {
		t.Fatal("expected error for unknown contract version")
	}
}

func TestParseUnmeshedIsNoError(t *testing.T) {
	stdin := []byte(`{"cniVersion":"1.0.0","name":"bridge","type":"wendy-mesh"}`)
	nc, err := Parse(stdin)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if nc.RuntimeConfig.Mesh.Enabled {
		t.Fatal("expected mesh disabled by default")
	}
}
