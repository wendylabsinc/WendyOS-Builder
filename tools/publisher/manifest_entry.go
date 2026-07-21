package main

import (
	"encoding/json"
	"fmt"
	"os"
)

// ManifestEntry is the handoff record between a build job running
// --upload-only and the publish job running --apply-metadata. It captures
// everything updateManifests needs so that manifest writes can happen in a
// single serialised job after all parallel builds have finished, instead of
// having every matrix entry race read-modify-writes on the shared manifests.
type ManifestEntry struct {
	Device    string `json:"device"`
	Version   string `json:"version"`
	Storage   string `json:"storage,omitempty"`
	Nightly   bool   `json:"nightly"`
	Stability string `json:"stability,omitempty"`
	// PR, when > 0, marks this entry as a per-PR debug build. It routes all
	// uploads and manifest writes into the self-contained pr/<N>/ subtree
	// instead of the shared release manifests. Zero for release/nightly.
	PR int `json:"pr,omitempty"`

	FilePath     string `json:"file_path,omitempty"`
	FileSize     int64  `json:"file_size,omitempty"`
	FileChecksum string `json:"file_checksum,omitempty"`
	BmapPath     string `json:"bmap_path,omitempty"`
	ZstPath      string `json:"zst_path,omitempty"`
	ZstChecksum  string `json:"zst_checksum,omitempty"`
	ZstSize      int64  `json:"zst_size_bytes,omitempty"`

	OTAUpdatePath     string `json:"ota_update_path,omitempty"`
	OTAUpdateSize     int64  `json:"ota_update_size,omitempty"`
	OTAUpdateChecksum string `json:"ota_update_checksum,omitempty"`

	RecoveryPath     string `json:"recovery_path,omitempty"`
	RecoverySize     int64  `json:"recovery_size,omitempty"`
	RecoveryChecksum string `json:"recovery_checksum,omitempty"`

	// Flashpack is the Jetson USB-recovery flash artifact (a .tar.zst the
	// wendy CLI downloads, extracts and flashes). Built per MACHINE, so
	// Storage above disambiguates variants sharing a device manifest.
	FlashpackPath     string `json:"flashpack_path,omitempty"`
	FlashpackSize     int64  `json:"flashpack_size,omitempty"`
	FlashpackChecksum string `json:"flashpack_checksum,omitempty"`

	// SBOM is the image-level SPDX Software Bill of Materials bundle
	// (a .spdx.tar.zst produced by the create-spdx class). It is an audit
	// artifact, not something the OTA client flashes; recording it in the
	// manifest just makes it discoverable alongside the image it describes.
	SBOMPath     string `json:"sbom_path,omitempty"`
	SBOMSize     int64  `json:"sbom_size,omitempty"`
	SBOMChecksum string `json:"sbom_checksum,omitempty"`

	// Extensions are driver add-ons (systemd-sysext .raw images) uploaded with
	// this build; carried through to the per-version manifest record verbatim.
	Extensions []ExtensionMetadata `json:"extensions,omitempty"`
}

func (e *ManifestEntry) validate() error {
	if err := validateDeviceType(e.Device); err != nil {
		return fmt.Errorf("invalid device: %w", err)
	}
	if err := validateVersion(e.Version); err != nil {
		return fmt.Errorf("invalid version: %w", err)
	}
	if e.Stability != "" {
		if err := validateStability(e.Stability); err != nil {
			return fmt.Errorf("invalid stability: %w", err)
		}
	}
	if e.Storage != "" && e.Storage != "nvme" && e.Storage != "sd" && e.Storage != "emmc" {
		return fmt.Errorf("invalid storage %q: must be nvme, sd, or emmc", e.Storage)
	}
	if e.FilePath == "" && e.OTAUpdatePath == "" && e.RecoveryPath == "" && e.FlashpackPath == "" {
		return fmt.Errorf("entry contains no files - at least one OS image, OTA update, recovery file, or flashpack is required")
	}
	return nil
}

// writeManifestEntry validates and writes an entry as indented JSON.
func writeManifestEntry(path string, entry ManifestEntry) error {
	if err := entry.validate(); err != nil {
		return err
	}
	content, err := json.MarshalIndent(entry, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, content, 0o644)
}

// readManifestEntry reads and validates an entry written by --upload-only.
func readManifestEntry(path string) (ManifestEntry, error) {
	var entry ManifestEntry
	content, err := os.ReadFile(path)
	if err != nil {
		return entry, err
	}
	if err := json.Unmarshal(content, &entry); err != nil {
		return entry, fmt.Errorf("parsing %s: %w", path, err)
	}
	if err := entry.validate(); err != nil {
		return entry, fmt.Errorf("validating %s: %w", path, err)
	}
	return entry, nil
}

// prPrefix returns the GCS object-path prefix for a per-PR build ("pr/<N>/"),
// or "" for a normal release/nightly build (pr <= 0).
func prPrefix(pr int) string {
	if pr <= 0 {
		return ""
	}
	return fmt.Sprintf("pr/%d/", pr)
}
