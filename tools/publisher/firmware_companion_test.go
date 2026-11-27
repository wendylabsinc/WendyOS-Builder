package main

import (
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFirmwareCompanionMetadata(t *testing.T) {
	root := t.TempDir()
	radio := filepath.Join(root, "radio.bin")
	host := filepath.Join(root, "host.bin")
	id := "wendy-" + strings.Repeat("0", 24)
	image := make([]byte, 80)
	image[0] = 0xe9
	binary.LittleEndian.PutUint16(image[12:14], 13)
	binary.LittleEndian.PutUint32(image[32:36], 0xabcd5432)
	copy(image[48:80], id)
	if err := os.WriteFile(radio, image, 0600); err != nil {
		t.Fatal(err)
	}
	if err := validateFirmwareCompanion(host, radio, id); err != nil {
		t.Fatal(err)
	}
	if err := validateFirmwareCompanion(host, radio, "wendy-"+strings.Repeat("1", 24)); err == nil {
		t.Fatal("accepted companion binary with a different identity")
	}
	if err := validateFirmwareCompanion(radio, radio, id); err == nil {
		t.Fatal("accepted the same destination for the host and companion")
	}

	manifest := FirmwareManifest{Versions: map[string]FirmwareVersionMetadata{
		"1.0.0": {Path: "host.bin"},
		"1.1.0": {Path: "host.bin", Companion: &FirmwareCompanionMetadata{
			BuildID: id, Path: "radio.bin", Checksum: strings.Repeat("a", 64), SizeBytes: 80,
		}},
	}}
	wire, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	var back FirmwareManifest
	if err := json.Unmarshal(wire, &back); err != nil {
		t.Fatal(err)
	}
	if back.Versions["1.0.0"].Companion != nil || back.Versions["1.1.0"].Companion == nil ||
		*back.Versions["1.1.0"].Companion != *manifest.Versions["1.1.0"].Companion {
		t.Fatalf("companion manifest did not round-trip: %s", wire)
	}
}
