package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func validEntry() ManifestEntry {
	return ManifestEntry{
		Device:            "jetson-agx-orin",
		Version:           "0.15.1-nightly",
		Storage:           "emmc",
		Nightly:           true,
		Stability:         "stable",
		FilePath:          "images/jetson-agx-orin/0.15.1-nightly/wendyos-image.tegraflash.tar.gz",
		FileSize:          2971666096,
		FileChecksum:      "21f44094492a79d77b0e4ee248eafc9a11b819470e7eb6459ada5ab018328827",
		OTAUpdatePath:     "images/jetson-agx-orin/0.15.1-nightly/wendyos-image.mender",
		OTAUpdateSize:     2889977344,
		OTAUpdateChecksum: "d04d8a8991e621bf62f4bcde5882973bd2cb2948dc841e3469874de2cdddcc66",
		SBOMPath:          "images/jetson-agx-orin/0.15.1-nightly/wendyos-image.spdx.tar.zst",
		SBOMSize:          14829056,
		SBOMChecksum:      "9f2c1e6c0b7a4d3e8f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e",
	}
}

func TestManifestEntryRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "entry.json")
	want := validEntry()

	if err := writeManifestEntry(path, want); err != nil {
		t.Fatalf("writeManifestEntry: %v", err)
	}
	got, err := readManifestEntry(path)
	if err != nil {
		t.Fatalf("readManifestEntry: %v", err)
	}
	if got != want {
		t.Errorf("round-trip mismatch:\n got %+v\nwant %+v", got, want)
	}
}

func TestManifestEntryValidate(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(*ManifestEntry)
		wantErr string
	}{
		{"valid", func(e *ManifestEntry) {}, ""},
		{"empty device", func(e *ManifestEntry) { e.Device = "" }, "invalid device"},
		{"empty version", func(e *ManifestEntry) { e.Version = "" }, "invalid version"},
		{"version with slash", func(e *ManifestEntry) { e.Version = "0.1/../evil" }, "invalid version"},
		{"bad storage", func(e *ManifestEntry) { e.Storage = "floppy" }, "invalid storage"},
		{"bad stability", func(e *ManifestEntry) { e.Stability = "wobbly" }, "invalid stability"},
		{"empty storage ok", func(e *ManifestEntry) { e.Storage = "" }, ""},
		{"empty stability ok", func(e *ManifestEntry) { e.Stability = "" }, ""},
		{"no files", func(e *ManifestEntry) {
			e.FilePath, e.OTAUpdatePath, e.RecoveryPath = "", "", ""
		}, "no files"},
		{"sbom alone is not a flashable file", func(e *ManifestEntry) {
			// An SBOM is an audit artifact, never the sole payload of an entry;
			// at least one flashable file (image/OTA/recovery) is still required.
			e.FilePath, e.OTAUpdatePath, e.RecoveryPath = "", "", ""
			e.SBOMPath = "images/d/v/wendyos-image.spdx.tar.zst"
		}, "no files"},
		{"recovery only ok", func(e *ManifestEntry) {
			e.FilePath, e.OTAUpdatePath = "", ""
			e.RecoveryPath = "images/d/v/recovery.tar.gz"
		}, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entry := validEntry()
			tt.mutate(&entry)
			err := entry.validate()
			if tt.wantErr == "" {
				if err != nil {
					t.Errorf("validate() = %v, want nil", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("validate() = %v, want error containing %q", err, tt.wantErr)
			}
		})
	}
}

func TestReadManifestEntryRejectsGarbage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "garbage.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := readManifestEntry(path); err == nil {
		t.Error("readManifestEntry accepted malformed JSON")
	}
	if _, err := readManifestEntry(filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Error("readManifestEntry accepted a missing file")
	}
}
