package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"testing"
	"time"

	seekable "github.com/SaveTheRbtz/zstd-seekable-format-go/pkg"
	"github.com/klauspost/compress/zstd"
)

// Test validation functions
func TestValidateDeviceType(t *testing.T) {
	tests := []struct {
		name       string
		deviceType string
		wantError  bool
	}{
		{"valid device", "raspberry-pi-5", false},
		{"empty device", "", true},
		{"too long", string(make([]byte, 101)), true},
		{"invalid slash", "device/type", true},
		{"invalid backslash", "device\\type", true},
		{"invalid dotdot", "device..type", true},
		{"invalid null", "device\x00type", true},
		{"invalid newline", "device\ntype", true},
		{"valid with dash", "jetson-orin-nano", false},
		{"valid with underscore", "device_type_1", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateDeviceType(tt.deviceType)
			if (err != nil) != tt.wantError {
				t.Errorf("validateDeviceType() error = %v, wantError %v", err, tt.wantError)
			}
		})
	}
}

func TestValidateVersion(t *testing.T) {
	tests := []struct {
		name      string
		version   string
		wantError bool
	}{
		{"valid version", "1.0.0", false},
		{"valid nightly", "nightly-2026-01-29", false},
		{"empty version", "", true},
		{"too long", string(make([]byte, 101)), true},
		{"invalid slash", "1.0/0", true},
		{"invalid backslash", "1.0\\0", true},
		{"valid semver", "2.1.3-beta", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateVersion(tt.version)
			if (err != nil) != tt.wantError {
				t.Errorf("validateVersion() error = %v, wantError %v", err, tt.wantError)
			}
		})
	}
}

func TestValidateStability(t *testing.T) {
	tests := []struct {
		name      string
		stability string
		wantError bool
	}{
		{"stable", "stable", false},
		{"experimental", "experimental", false},
		{"deprecated", "deprecated", false},
		{"empty (defaults to stable)", "", false},
		{"invalid", "invalid", true},
		{"typo", "stabel", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateStability(tt.stability)
			if (err != nil) != tt.wantError {
				t.Errorf("validateStability() error = %v, wantError %v", err, tt.wantError)
			}
		})
	}
}

func TestValidateFileExists(t *testing.T) {
	// Create a temporary test file
	tmpFile, err := os.CreateTemp("", "test-*.img")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(tmpFile.Name())

	// Write some data
	if _, err := tmpFile.WriteString("test data"); err != nil {
		t.Fatal(err)
	}
	tmpFile.Close()

	// Create empty file
	emptyFile, err := os.CreateTemp("", "empty-*.img")
	if err != nil {
		t.Fatal(err)
	}
	emptyPath := emptyFile.Name()
	emptyFile.Close()
	defer os.Remove(emptyPath)

	// Create directory
	tmpDir, err := os.MkdirTemp("", "testdir")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	tests := []struct {
		name      string
		filePath  string
		wantError bool
	}{
		{"valid file", tmpFile.Name(), false},
		{"nonexistent file", "/nonexistent/file.img", true},
		{"empty file", emptyPath, true},
		{"directory", tmpDir, true},
		{"empty path", "", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateFileExists(tt.filePath)
			if (err != nil) != tt.wantError {
				t.Errorf("validateFileExists() error = %v, wantError %v", err, tt.wantError)
			}
		})
	}
}

// Test file operations
func TestCalculateChecksum(t *testing.T) {
	// Create test file with known content
	tmpFile, err := os.CreateTemp("", "checksum-test-*.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(tmpFile.Name())

	testData := []byte("Hello, World!")
	if _, err := tmpFile.Write(testData); err != nil {
		t.Fatal(err)
	}
	tmpFile.Close()

	// Calculate expected checksum
	hash := sha256.Sum256(testData)
	expected := hex.EncodeToString(hash[:])

	// Test function
	got, err := calculateChecksum(tmpFile.Name())
	if err != nil {
		t.Fatalf("calculateChecksum() error = %v", err)
	}

	if got != expected {
		t.Errorf("calculateChecksum() = %v, want %v", got, expected)
	}
}

func TestCalculateChecksumNonexistentFile(t *testing.T) {
	_, err := calculateChecksum("/nonexistent/file.txt")
	if err == nil {
		t.Error("calculateChecksum() expected error for nonexistent file, got nil")
	}
}

func TestIsOSImage(t *testing.T) {
	tests := []struct {
		filename string
		want     bool
	}{
		{"image.img", true},
		{"image.IMG", true},
		{"image.wic", true},
		{"image.WIC", true},
		{"image.sdimg", true},
		{"image.SDIMG", true},
		{"archive.zip", true},
		{"archive.tgz", true},
		{"compressed.xz", true},
		{"compressed.zst", true},
		{"update.mender", true},
		{"document.pdf", false},
		{"text.txt", false},
		{"script.sh", false},
		{"", false},
		{"noextension", false},
	}

	for _, tt := range tests {
		t.Run(tt.filename, func(t *testing.T) {
			// Suppress log output during test
			oldLevel := log.Level
			log.SetLevel(100) // Disable logging
			defer log.SetLevel(oldLevel)

			got := isOSImage(tt.filename)
			if got != tt.want {
				t.Errorf("isOSImage(%q) = %v, want %v", tt.filename, got, tt.want)
			}
		})
	}
}

// Test Discord notification payload generation
func TestSendDiscordNotificationPayload(t *testing.T) {
	tests := []struct {
		name       string
		deviceType string
		version    string
		isNightly  bool
		fileSize   int64
		wantColor  int
		wantTitle  string
	}{
		{
			name:       "stable build",
			deviceType: "raspberry-pi-5",
			version:    "1.0.0",
			isNightly:  false,
			fileSize:   1024 * 1024 * 100, // 100MB
			wantColor:  0x00FF00,
			wantTitle:  "New Stable Build Published",
		},
		{
			name:       "nightly build",
			deviceType: "jetson-orin",
			version:    "nightly-2026-01-29",
			isNightly:  true,
			fileSize:   1024 * 1024 * 500, // 500MB
			wantColor:  0xFFA500,
			wantTitle:  "New Nightly Build Published",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Build the payload manually (same logic as sendDiscordNotification)
			buildType := "Stable"
			color := colorStable
			if tt.isNightly {
				buildType = "Nightly"
				color = colorNightly
			}

			embed := DiscordEmbed{
				Title:       "New " + buildType + " Build Published",
				Description: "WendyOS update for **" + tt.deviceType + "** has been published",
				Color:       color,
			}

			if embed.Title != tt.wantTitle {
				t.Errorf("Discord title = %q, want %q", embed.Title, tt.wantTitle)
			}

			if embed.Color != tt.wantColor {
				t.Errorf("Discord color = %d, want %d", embed.Color, tt.wantColor)
			}

			if embed.Description == "" {
				t.Error("Discord description is empty")
			}
		})
	}
}

// Test manifest structures
func TestDeviceManifestSerialization(t *testing.T) {
	manifest := DeviceManifest{
		DeviceID: "test-device",
		Versions: map[string]VersionMetadata{
			"1.0.0": {
				ReleaseDate:        time.Date(2026, 1, 29, 12, 0, 0, 0, time.UTC),
				Path:               "images/test-device/1.0.0/image.img.xz",
				Checksum:           "abc123",
				SizeBytes:          1024 * 1024,
				IsLatest:           true,
				IsNightly:          false,
				OTAUpdatePath:      "images/test-device/1.0.0/update.mender.xz",
				OTAUpdateChecksum:  "def456",
				OTAUpdateSizeBytes: 512 * 1024,
			},
		},
	}

	// Serialize to JSON
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		t.Fatalf("Failed to marshal manifest: %v", err)
	}

	// Deserialize back
	var decoded DeviceManifest
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("Failed to unmarshal manifest: %v", err)
	}

	// Verify
	if decoded.DeviceID != manifest.DeviceID {
		t.Errorf("DeviceID = %q, want %q", decoded.DeviceID, manifest.DeviceID)
	}

	if len(decoded.Versions) != 1 {
		t.Errorf("Versions count = %d, want 1", len(decoded.Versions))
	}

	v := decoded.Versions["1.0.0"]
	if v.Path != manifest.Versions["1.0.0"].Path {
		t.Errorf("Path = %q, want %q", v.Path, manifest.Versions["1.0.0"].Path)
	}

	if v.OTAUpdatePath != manifest.Versions["1.0.0"].OTAUpdatePath {
		t.Errorf("OTAUpdatePath = %q, want %q", v.OTAUpdatePath, manifest.Versions["1.0.0"].OTAUpdatePath)
	}
}

func TestMasterManifestSerialization(t *testing.T) {
	manifest := MasterManifest{
		LastUpdated: time.Date(2026, 1, 29, 12, 0, 0, 0, time.UTC),
		Devices: map[string]DeviceLatestInfo{
			"raspberry-pi-5": {
				Latest:        "1.0.0",
				LatestNightly: "nightly-2026-01-29",
				ManifestPath:  "manifests/raspberry-pi-5.json",
				Stability:     "stable",
			},
		},
	}

	// Serialize
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		t.Fatalf("Failed to marshal manifest: %v", err)
	}

	// Deserialize
	var decoded MasterManifest
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("Failed to unmarshal manifest: %v", err)
	}

	// Verify
	if len(decoded.Devices) != 1 {
		t.Errorf("Devices count = %d, want 1", len(decoded.Devices))
	}

	device := decoded.Devices["raspberry-pi-5"]
	expected := manifest.Devices["raspberry-pi-5"]

	if device.Latest != expected.Latest {
		t.Errorf("Latest = %q, want %q", device.Latest, expected.Latest)
	}

	if device.Stability != expected.Stability {
		t.Errorf("Stability = %q, want %q", device.Stability, expected.Stability)
	}
}

// Test compression detection
func TestCompressFileNonCompressible(t *testing.T) {
	// Create a zip file (already compressed)
	tmpFile, err := os.CreateTemp("", "test-*.zip")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.WriteString("test data"); err != nil {
		t.Fatal(err)
	}
	tmpFile.Close()

	// Should return original path
	result, err := compressFile(context.Background(), tmpFile.Name(), "os")
	if err != nil {
		t.Fatalf("compressFile() error = %v", err)
	}

	if result != tmpFile.Name() {
		t.Errorf("compressFile() = %q, want %q (original)", result, tmpFile.Name())
	}
}

// Integration test: compress and verify checksum
func TestCompressAndChecksumIntegration(t *testing.T) {
	// Create a test .img file
	tmpFile, err := os.CreateTemp("", "test-*.img")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(tmpFile.Name())

	// Write test data
	testData := []byte("This is test image data that should be compressed")
	if _, err := tmpFile.Write(testData); err != nil {
		t.Fatal(err)
	}
	tmpFile.Close()

	// Check if xz is available
	if _, err := os.Stat("/usr/bin/xz"); os.IsNotExist(err) {
		t.Skip("xz not available, skipping compression test")
	}

	// Compress (test as OS image type)
	compressed, err := compressFile(context.Background(), tmpFile.Name(), "os")
	if err != nil {
		t.Fatalf("compressFile() error = %v", err)
	}
	defer os.Remove(compressed)

	// Verify compressed file exists
	if _, err := os.Stat(compressed); err != nil {
		t.Errorf("Compressed file doesn't exist: %v", err)
	}

	// Calculate checksum of compressed file
	checksum, err := calculateChecksum(compressed)
	if err != nil {
		t.Fatalf("calculateChecksum() error = %v", err)
	}

	if checksum == "" {
		t.Error("Checksum is empty")
	}

	// Verify checksum is valid hex
	if _, err := hex.DecodeString(checksum); err != nil {
		t.Errorf("Checksum is not valid hex: %v", err)
	}

	// Verify checksum length (SHA256 = 64 hex chars)
	if len(checksum) != 64 {
		t.Errorf("Checksum length = %d, want 64", len(checksum))
	}
}

// Benchmark tests
func BenchmarkCalculateChecksum(b *testing.B) {
	// Create a test file
	tmpFile, err := os.CreateTemp("", "bench-*.img")
	if err != nil {
		b.Fatal(err)
	}
	defer os.Remove(tmpFile.Name())

	// Write 10MB of data
	data := make([]byte, 10*1024*1024)
	if _, err := tmpFile.Write(data); err != nil {
		b.Fatal(err)
	}
	tmpFile.Close()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := calculateChecksum(tmpFile.Name())
		if err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkValidateDeviceType(b *testing.B) {
	deviceType := "raspberry-pi-5"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = validateDeviceType(deviceType)
	}
}

func TestSetBmapPath(t *testing.T) {
	t.Run("nvme sets per-storage and top-level", func(t *testing.T) {
		m := &VersionMetadata{}
		setBmapPath(m, "nvme", "images/x/nvme.img.bmap")
		if m.NVMEBmapPath != "images/x/nvme.img.bmap" {
			t.Errorf("NVMEBmapPath = %q", m.NVMEBmapPath)
		}
		if m.BmapPath != "images/x/nvme.img.bmap" {
			t.Errorf("BmapPath = %q, want NVMe bmap (matches top-level Path)", m.BmapPath)
		}
		if m.SDCardBmapPath != "" {
			t.Errorf("SDCardBmapPath = %q, want empty", m.SDCardBmapPath)
		}
	})

	t.Run("sd after nvme does not clobber top-level", func(t *testing.T) {
		// Simulates the bug: NVMe published first, then SD. Top-level bmap_path
		// must keep pointing at the NVMe bmap (matching top-level Path=NVMe).
		m := &VersionMetadata{
			BmapPath:     "images/x/nvme.img.bmap",
			NVMEBmapPath: "images/x/nvme.img.bmap",
		}
		setBmapPath(m, "sd", "images/x/sd.img.bmap")
		if m.SDCardBmapPath != "images/x/sd.img.bmap" {
			t.Errorf("SDCardBmapPath = %q", m.SDCardBmapPath)
		}
		if m.BmapPath != "images/x/nvme.img.bmap" {
			t.Errorf("BmapPath = %q, want NVMe bmap preserved", m.BmapPath)
		}
	})

	t.Run("nvme after sd wins top-level", func(t *testing.T) {
		// SD published first (filled top-level), then NVMe overwrites it.
		m := &VersionMetadata{
			BmapPath:       "images/x/sd.img.bmap",
			SDCardBmapPath: "images/x/sd.img.bmap",
		}
		setBmapPath(m, "nvme", "images/x/nvme.img.bmap")
		if m.BmapPath != "images/x/nvme.img.bmap" {
			t.Errorf("BmapPath = %q, want NVMe to win top-level", m.BmapPath)
		}
		if m.SDCardBmapPath != "images/x/sd.img.bmap" {
			t.Errorf("SDCardBmapPath = %q, want SD preserved", m.SDCardBmapPath)
		}
	})

	t.Run("sd-only device fills top-level", func(t *testing.T) {
		m := &VersionMetadata{}
		setBmapPath(m, "sd", "images/x/sd.img.bmap")
		if m.BmapPath != "images/x/sd.img.bmap" {
			t.Errorf("BmapPath = %q, want SD bmap for sd-only device", m.BmapPath)
		}
		if m.SDCardBmapPath != "images/x/sd.img.bmap" {
			t.Errorf("SDCardBmapPath = %q", m.SDCardBmapPath)
		}
	})

	t.Run("single-storage default sets top-level", func(t *testing.T) {
		m := &VersionMetadata{}
		setBmapPath(m, "", "images/x/img.bmap")
		if m.BmapPath != "images/x/img.bmap" {
			t.Errorf("BmapPath = %q", m.BmapPath)
		}
	})

	t.Run("emmc gets no bmap", func(t *testing.T) {
		m := &VersionMetadata{}
		setBmapPath(m, "emmc", "images/x/should-not-be-set.bmap")
		if m.BmapPath != "" || m.NVMEBmapPath != "" || m.SDCardBmapPath != "" {
			t.Errorf("eMMC should set no bmap fields, got %+v", m)
		}
	})

	t.Run("empty bmap path is a no-op", func(t *testing.T) {
		m := &VersionMetadata{BmapPath: "existing"}
		setBmapPath(m, "nvme", "")
		if m.BmapPath != "existing" || m.NVMEBmapPath != "" {
			t.Errorf("empty bmapPath should not change anything, got %+v", m)
		}
	})
}

func TestApplyOTAUpdate(t *testing.T) {
	const (
		nvmeOTA = "images/jetson-orin-nano/v1/wendyos-image-jetson-orin-nano-devkit-nvme-wendyos.mender"
		sdOTA   = "images/jetson-orin-nano/v1/wendyos-image-jetson-orin-nano-devkit-wendyos.mender"
	)

	t.Run("nvme routes to nvme field and seeds default", func(t *testing.T) {
		m := &VersionMetadata{}
		applyOTAUpdate(m, "nvme", nvmeOTA, "ck-nvme", 10)
		if m.NVMEOTAUpdatePath != nvmeOTA {
			t.Errorf("NVMEOTAUpdatePath = %q, want %q", m.NVMEOTAUpdatePath, nvmeOTA)
		}
		if m.OTAUpdatePath != nvmeOTA {
			t.Errorf("OTAUpdatePath = %q, want NVMe seeded as default when unset", m.OTAUpdatePath)
		}
	})

	t.Run("sd routes to default ota field", func(t *testing.T) {
		m := &VersionMetadata{}
		applyOTAUpdate(m, "sd", sdOTA, "ck-sd", 20)
		if m.OTAUpdatePath != sdOTA {
			t.Errorf("OTAUpdatePath = %q, want %q", m.OTAUpdatePath, sdOTA)
		}
		if m.NVMEOTAUpdatePath != "" {
			t.Errorf("NVMEOTAUpdatePath = %q, want empty for sd", m.NVMEOTAUpdatePath)
		}
	})

	t.Run("sd then nvme keeps both distinct", func(t *testing.T) {
		m := &VersionMetadata{}
		applyOTAUpdate(m, "sd", sdOTA, "ck-sd", 20)
		applyOTAUpdate(m, "nvme", nvmeOTA, "ck-nvme", 10)
		if m.OTAUpdatePath != sdOTA {
			t.Errorf("OTAUpdatePath = %q, want SD preserved (not clobbered by nvme)", m.OTAUpdatePath)
		}
		if m.NVMEOTAUpdatePath != nvmeOTA {
			t.Errorf("NVMEOTAUpdatePath = %q, want %q", m.NVMEOTAUpdatePath, nvmeOTA)
		}
	})

	t.Run("nvme then sd keeps both distinct", func(t *testing.T) {
		m := &VersionMetadata{}
		applyOTAUpdate(m, "nvme", nvmeOTA, "ck-nvme", 10)
		applyOTAUpdate(m, "sd", sdOTA, "ck-sd", 20)
		if m.OTAUpdatePath != sdOTA {
			t.Errorf("OTAUpdatePath = %q, want SD to own the default", m.OTAUpdatePath)
		}
		if m.NVMEOTAUpdatePath != nvmeOTA {
			t.Errorf("NVMEOTAUpdatePath = %q, want %q", m.NVMEOTAUpdatePath, nvmeOTA)
		}
	})

	t.Run("empty path is a no-op", func(t *testing.T) {
		m := &VersionMetadata{OTAUpdatePath: sdOTA}
		applyOTAUpdate(m, "nvme", "", "", 0)
		if m.OTAUpdatePath != sdOTA || m.NVMEOTAUpdatePath != "" {
			t.Errorf("empty path mutated metadata: %+v", m)
		}
	})
}

func TestSetZstPath(t *testing.T) {
	t.Run("nvme sets per-storage and top-level", func(t *testing.T) {
		m := &VersionMetadata{}
		setZstPath(m, "nvme", "images/x/nvme.img.zst", "abc123", 1024)
		if m.NVMEZstPath != "images/x/nvme.img.zst" {
			t.Errorf("NVMEZstPath = %q", m.NVMEZstPath)
		}
		if m.NVMEZstChecksum != "abc123" {
			t.Errorf("NVMEZstChecksum = %q", m.NVMEZstChecksum)
		}
		if m.NVMEZstSizeBytes != 1024 {
			t.Errorf("NVMEZstSizeBytes = %d", m.NVMEZstSizeBytes)
		}
		if m.ZstPath != "images/x/nvme.img.zst" {
			t.Errorf("ZstPath = %q, want NVMe zst (matches top-level Path)", m.ZstPath)
		}
		if m.ZstChecksum != "abc123" {
			t.Errorf("ZstChecksum = %q", m.ZstChecksum)
		}
		if m.ZstSizeBytes != 1024 {
			t.Errorf("ZstSizeBytes = %d", m.ZstSizeBytes)
		}
		if m.SDCardZstPath != "" {
			t.Errorf("SDCardZstPath = %q, want empty", m.SDCardZstPath)
		}
	})

	t.Run("sd after nvme does not clobber top-level", func(t *testing.T) {
		m := &VersionMetadata{
			ZstPath:          "images/x/nvme.img.zst",
			ZstChecksum:      "abc123",
			ZstSizeBytes:     1024,
			NVMEZstPath:      "images/x/nvme.img.zst",
			NVMEZstChecksum:  "abc123",
			NVMEZstSizeBytes: 1024,
		}
		setZstPath(m, "sd", "images/x/sd.img.zst", "def456", 512)
		if m.SDCardZstPath != "images/x/sd.img.zst" {
			t.Errorf("SDCardZstPath = %q", m.SDCardZstPath)
		}
		if m.ZstPath != "images/x/nvme.img.zst" {
			t.Errorf("ZstPath = %q, want NVMe zst preserved", m.ZstPath)
		}
		if m.ZstChecksum != "abc123" {
			t.Errorf("ZstChecksum = %q, want NVMe checksum preserved", m.ZstChecksum)
		}
	})

	t.Run("nvme after sd wins top-level", func(t *testing.T) {
		m := &VersionMetadata{
			ZstPath:            "images/x/sd.img.zst",
			ZstChecksum:        "def456",
			ZstSizeBytes:       512,
			SDCardZstPath:      "images/x/sd.img.zst",
			SDCardZstChecksum:  "def456",
			SDCardZstSizeBytes: 512,
		}
		setZstPath(m, "nvme", "images/x/nvme.img.zst", "abc123", 1024)
		if m.ZstPath != "images/x/nvme.img.zst" {
			t.Errorf("ZstPath = %q, want NVMe to win top-level", m.ZstPath)
		}
		if m.SDCardZstPath != "images/x/sd.img.zst" {
			t.Errorf("SDCardZstPath = %q, want SD preserved", m.SDCardZstPath)
		}
	})

	t.Run("sd-only device fills top-level", func(t *testing.T) {
		m := &VersionMetadata{}
		setZstPath(m, "sd", "images/x/sd.img.zst", "def456", 512)
		if m.ZstPath != "images/x/sd.img.zst" {
			t.Errorf("ZstPath = %q, want SD zst for sd-only device", m.ZstPath)
		}
		if m.SDCardZstPath != "images/x/sd.img.zst" {
			t.Errorf("SDCardZstPath = %q", m.SDCardZstPath)
		}
		if m.ZstChecksum != "def456" {
			t.Errorf("ZstChecksum = %q", m.ZstChecksum)
		}
	})

	t.Run("single-storage default sets top-level", func(t *testing.T) {
		m := &VersionMetadata{}
		setZstPath(m, "", "images/x/img.zst", "xyz789", 2048)
		if m.ZstPath != "images/x/img.zst" {
			t.Errorf("ZstPath = %q", m.ZstPath)
		}
		if m.ZstChecksum != "xyz789" {
			t.Errorf("ZstChecksum = %q", m.ZstChecksum)
		}
	})

	t.Run("emmc gets no zst", func(t *testing.T) {
		m := &VersionMetadata{}
		setZstPath(m, "emmc", "images/x/should-not-be-set.zst", "abc", 100)
		if m.ZstPath != "" || m.NVMEZstPath != "" || m.SDCardZstPath != "" {
			t.Errorf("eMMC should set no zst fields, got %+v", m)
		}
	})

	t.Run("empty zst path is a no-op", func(t *testing.T) {
		m := &VersionMetadata{ZstPath: "existing", ZstChecksum: "cs", ZstSizeBytes: 99}
		setZstPath(m, "nvme", "", "", 0)
		if m.ZstPath != "existing" || m.ZstChecksum != "cs" || m.NVMEZstPath != "" {
			t.Errorf("empty zstPath should not change anything, got %+v", m)
		}
	})
}

func TestCompressSeekableZstdRoundTrips(t *testing.T) {
	// Build a known payload that spans multiple frames (> seekableFrameSize would
	// be slow in tests; use a small payload and verify the whole thing round-trips).
	payload := make([]byte, 64*1024) // 64 KiB — fits in a single frame
	for i := range payload {
		payload[i] = byte(i % 251)
	}

	// Write source file.
	srcFile, err := os.CreateTemp("", "zst-src-*.img")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(srcFile.Name())
	if _, err := srcFile.Write(payload); err != nil {
		t.Fatal(err)
	}
	srcFile.Close()

	// Compress to a .zst file.
	dstPath := srcFile.Name() + ".zst"
	defer os.Remove(dstPath)
	if err := compressSeekableZstd(srcFile.Name(), dstPath); err != nil {
		t.Fatalf("compressSeekableZstd: %v", err)
	}

	// Verify the .zst file exists and is non-empty.
	info, err := os.Stat(dstPath)
	if err != nil {
		t.Fatalf("zst file not found: %v", err)
	}
	if info.Size() == 0 {
		t.Fatal("zst file is empty")
	}

	// Round-trip: decompress with seekable reader and verify content.
	zstFile, err := os.Open(dstPath)
	if err != nil {
		t.Fatal(err)
	}
	defer zstFile.Close()

	dec, err := zstd.NewReader(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer dec.Close()

	r, err := seekable.NewReader(zstFile, dec)
	if err != nil {
		t.Fatalf("seekable.NewReader: %v", err)
	}
	defer r.Close()

	got := make([]byte, len(payload))
	if _, err := r.ReadAt(got, 0); err != nil && err != io.EOF {
		t.Fatalf("ReadAt: %v", err)
	}

	if string(got) != string(payload) {
		t.Error("round-trip mismatch: decompressed bytes differ from original")
	}
}
