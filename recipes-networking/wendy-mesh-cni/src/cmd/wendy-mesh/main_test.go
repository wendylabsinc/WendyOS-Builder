package main

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"

	"github.com/containernetworking/cni/pkg/skel"
)

func TestCmdAddUnmeshedIsPassthrough(t *testing.T) {
	stdin := []byte(`{
		"cniVersion":"1.0.0","name":"bridge","type":"wendy-mesh",
		"prevResult":{"cniVersion":"1.0.0","interfaces":[],
			"ips":[{"address":"10.88.0.5/16","interface":0}]}
	}`)
	args := &skel.CmdArgs{StdinData: stdin}

	out := captureStdout(t, func() {
		if err := cmdAdd(args); err != nil {
			t.Fatalf("unmeshed cmdAdd must not error: %v", err)
		}
	})
	if !strings.Contains(out, `"10.88.0.5/16"`) {
		t.Fatalf("passthrough must echo prevResult, got: %s", out)
	}
}

// captureStdout redirects os.Stdout for the duration of fn and returns what was
// written (the plugin prints its CNI result to stdout).
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	orig := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w
	defer func() { os.Stdout = orig }()

	fn()
	w.Close()
	var buf bytes.Buffer
	if _, err := io.Copy(&buf, r); err != nil {
		t.Fatalf("copy: %v", err)
	}
	return buf.String()
}
