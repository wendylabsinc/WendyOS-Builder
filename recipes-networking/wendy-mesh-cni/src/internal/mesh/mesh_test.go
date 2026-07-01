package mesh

import (
	"net"
	"reflect"
	"testing"
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
