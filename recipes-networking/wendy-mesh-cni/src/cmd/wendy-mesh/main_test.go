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

// meshedNoPrevResultStdin is a meshed netconf with no "prevResult" key at all.
// wendy-mesh must not panic on this input: cmdDel must tolerate it (CNI DEL is
// frequently called without a prevResult), and cmdAdd/cmdCheck must fail closed
// with a clean error instead of panicking inside the CNI library.
const meshedNoPrevResultStdin = `{"cniVersion":"1.0.0","name":"bridge","type":"wendy-mesh",
 "runtimeConfig":{"mesh":{"contractVersion":1,"enabled":true,"serviceCIDR":"10.99.0.0/16","gateway":"10.88.0.1"}}}`

func TestCmdDelMeshedNoPrevResultReturnsNil(t *testing.T) {
	args := &skel.CmdArgs{StdinData: []byte(meshedNoPrevResultStdin)}
	if err := cmdDel(args); err != nil {
		t.Fatalf("meshed cmdDel with no prevResult must return nil (tolerate absent prevResult), got: %v", err)
	}
}

func TestCmdAddMeshedNoPrevResultFailsClosed(t *testing.T) {
	args := &skel.CmdArgs{StdinData: []byte(meshedNoPrevResultStdin)}
	if err := cmdAdd(args); err == nil {
		t.Fatal("meshed cmdAdd with no prevResult must fail closed with a non-nil error, got nil")
	}
}

func TestCmdCheckMeshedNoPrevResultFailsClosed(t *testing.T) {
	args := &skel.CmdArgs{StdinData: []byte(meshedNoPrevResultStdin)}
	if err := cmdCheck(args); err == nil {
		t.Fatal("meshed cmdCheck with no prevResult must fail closed with a non-nil error, got nil")
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
