package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"cloud.google.com/go/storage"
	seekable "github.com/SaveTheRbtz/zstd-seekable-format-go/pkg"
	"github.com/klauspost/compress/zstd"
	"github.com/sirupsen/logrus"
	"golang.org/x/oauth2"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/iterator"
	"google.golang.org/api/option"
)

var log = logrus.New()

// gcloudTokenSource implements oauth2.TokenSource. It seeds with the caller's
// initial access token and refreshes by running "gcloud auth print-access-token"
// once the token is within 10 seconds of expiry (the oauth2 package's Valid()
// check applies a 10-second buffer).
type gcloudTokenSource struct {
	mu    sync.Mutex
	token *oauth2.Token
}

func (s *gcloudTokenSource) Token() (*oauth2.Token, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token != nil && s.token.Valid() {
		return s.token, nil
	}
	out, err := exec.Command("gcloud", "auth", "print-access-token").Output()
	if err != nil {
		return nil, fmt.Errorf("gcloud token refresh failed: %w", err)
	}
	s.token = &oauth2.Token{
		AccessToken: strings.TrimSpace(string(out)),
		TokenType:   "Bearer",
		Expiry:      time.Now().Add(55 * time.Minute),
	}
	return s.token, nil
}

// manifestCacheControl is set on every manifest write. Manifests are mutable
// and read-modify-written under GenerationMatch preconditions; without this,
// GCS applies its default "public, max-age=3600" to publicly readable objects
// and serves reads (including our own) from its built-in edge cache. Stale
// reads carry stale generation numbers, which livelocks CAS retries with 412s
// and silently resurrects old state on unconditional writes — both observed
// in production (run 26967801954). "no-store" forces every manifest read,
// by CI and by device clients, to be strongly consistent.
const manifestCacheControl = "no-store"

// discordWebhookURL is read from the DISCORD_WEBHOOK_URL environment variable.
var discordWebhookURL = os.Getenv("DISCORD_WEBHOOK_URL")

// discordReleaseWebhookURL is read from the DISCORD_RELEASE_WEBHOOK_URL environment variable.
var discordReleaseWebhookURL = os.Getenv("DISCORD_RELEASE_WEBHOOK_URL")

// Discord embed colors
const (
	colorStable  = 0x00FF00 // Green for stable builds
	colorNightly = 0xFFA500 // Orange for nightly builds
)

// Validation constants
const (
	maxDeviceTypeLength = 100 // GCS object path component limit
	maxVersionLength    = 100 // GCS object path component limit
)

// DeviceManifest represents a device-specific manifest
type DeviceManifest struct {
	DeviceID string                     `json:"device_id"`
	Versions map[string]VersionMetadata `json:"versions"`
}

// VersionMetadata contains metadata about a specific OS version
type VersionMetadata struct {
	ReleaseDate        time.Time  `json:"release_date"`
	Path               string     `json:"path"`
	Checksum           string     `json:"checksum,omitempty"`
	SizeBytes          int64      `json:"size_bytes"`
	Changelog          string     `json:"changelog,omitempty"`
	IsLatest           bool       `json:"is_latest"`
	IsNightly          bool       `json:"is_nightly,omitempty"`
	PromotedFrom       *string    `json:"promoted_from,omitempty"`
	PromotedAt         *time.Time `json:"promoted_at,omitempty"`
	SwappedAt          *time.Time `json:"swapped_at,omitempty"`
	SwapCount          *int       `json:"swap_count,omitempty"`
	OTAUpdatePath      string     `json:"ota_update_path,omitempty"`
	OTAUpdateChecksum  string     `json:"ota_update_checksum,omitempty"`
	OTAUpdateSizeBytes int64      `json:"ota_update_size_bytes,omitempty"`
	RecoveryPath       string     `json:"recovery_path,omitempty"`
	RecoveryChecksum   string     `json:"recovery_checksum,omitempty"`
	RecoverySizeBytes  int64      `json:"recovery_size_bytes,omitempty"`
	FlashpackPath      string     `json:"flashpack_path,omitempty"`
	FlashpackChecksum  string     `json:"flashpack_checksum,omitempty"`
	FlashpackSizeBytes int64      `json:"flashpack_size_bytes,omitempty"`
	// SBOM is the image-level SPDX Software Bill of Materials bundle
	// (.spdx.tar.zst from the create-spdx class). It describes the OS image
	// contents and is not storage-specific, so a single top-level field
	// (last writer wins across storage variants) is sufficient. Older CLIs
	// ignore these unknown fields.
	SBOMPath      string `json:"sbom_path,omitempty"`
	SBOMChecksum  string `json:"sbom_checksum,omitempty"`
	SBOMSizeBytes int64  `json:"sbom_size_bytes,omitempty"`
	BmapPath      string `json:"bmap_path,omitempty"`
	// Storage-specific image paths for devices that produce multiple artifacts
	// (e.g. jetson-orin-nano which ships both an NVMe and an SD card image).
	// Path above stays set to the NVMe image for backwards compatibility with
	// older CLI versions that only know about the single Path field.
	NVMEPath        string `json:"nvme_path,omitempty"`
	NVMEChecksum    string `json:"nvme_checksum,omitempty"`
	NVMESizeBytes   int64  `json:"nvme_size_bytes,omitempty"`
	SDCardPath      string `json:"sd_path,omitempty"`
	SDCardChecksum  string `json:"sd_checksum,omitempty"`
	SDCardSizeBytes int64  `json:"sd_size_bytes,omitempty"`
	EMMCPath        string `json:"emmc_path,omitempty"`
	EMMCChecksum    string `json:"emmc_checksum,omitempty"`
	EMMCSizeBytes   int64  `json:"emmc_size_bytes,omitempty"`
	// Storage-specific block maps. Each .bmap describes one image, so it must
	// track the image it was generated from. The top-level BmapPath above
	// mirrors Path (the NVMe image on multi-storage devices) for older CLIs;
	// a CLI that flashes the SD variant uses SDCardBmapPath. eMMC has no
	// offline image, hence no bmap.
	NVMEBmapPath   string `json:"nvme_bmap_path,omitempty"`
	SDCardBmapPath string `json:"sd_bmap_path,omitempty"`
	// Storage-specific OTA (Mender) artifacts. The NVMe and SD/eMMC builds
	// produce distinct .mender artifacts whose embedded device_type differs,
	// so they cannot share a single ota_update_path. The CLI selects
	// nvme_ota_update_path when the device reports storage_medium=nvme;
	// otherwise it uses ota_update_path.
	NVMEOTAUpdatePath      string `json:"nvme_ota_update_path,omitempty"`
	NVMEOTAUpdateChecksum  string `json:"nvme_ota_update_checksum,omitempty"`
	NVMEOTAUpdateSizeBytes int64  `json:"nvme_ota_update_size_bytes,omitempty"`
	// Seekable-zstd images. The top-level ZstPath mirrors Path/BmapPath
	// semantics (NVMe wins, SD fills only when empty, eMMC has no offline
	// image hence no zst). Each zst carries a checksum and size so the CLI
	// can verify integrity before and after download without a separate bmap
	// file.
	ZstPath            string `json:"zst_path,omitempty"`
	ZstChecksum        string `json:"zst_checksum,omitempty"`
	ZstSizeBytes       int64  `json:"zst_size_bytes,omitempty"`
	NVMEZstPath        string `json:"nvme_zst_path,omitempty"`
	NVMEZstChecksum    string `json:"nvme_zst_checksum,omitempty"`
	NVMEZstSizeBytes   int64  `json:"nvme_zst_size_bytes,omitempty"`
	SDCardZstPath      string `json:"sd_zst_path,omitempty"`
	SDCardZstChecksum  string `json:"sd_zst_checksum,omitempty"`
	SDCardZstSizeBytes int64  `json:"sd_zst_size_bytes,omitempty"`
}

// MasterManifest represents the top-level manifest
type MasterManifest struct {
	LastUpdated time.Time                   `json:"last_updated"`
	Devices     map[string]DeviceLatestInfo `json:"devices"`
	Firmware    map[string]DeviceLatestInfo `json:"firmware,omitempty"`
}

// DeviceLatestInfo holds info about the latest version for a device
type DeviceLatestInfo struct {
	Latest        string `json:"latest"`
	LatestNightly string `json:"latest_nightly,omitempty"`
	ManifestPath  string `json:"manifest_path"`
	Stability     string `json:"stability,omitempty"` // "stable", "experimental", "deprecated"
}

// FirmwareManifest represents a chip-specific firmware manifest
type FirmwareManifest struct {
	ChipID   string                             `json:"chip_id"`
	Versions map[string]FirmwareVersionMetadata `json:"versions"`
}

// FirmwareVersionMetadata contains metadata about a specific firmware version
type FirmwareVersionMetadata struct {
	ReleaseDate  time.Time  `json:"release_date"`
	Path         string     `json:"path"`
	Checksum     string     `json:"checksum,omitempty"`
	SizeBytes    int64      `json:"size_bytes"`
	Changelog    string     `json:"changelog,omitempty"`
	IsLatest     bool       `json:"is_latest"`
	IsNightly    bool       `json:"is_nightly,omitempty"`
	PromotedFrom *string    `json:"promoted_from,omitempty"`
	PromotedAt   *time.Time `json:"promoted_at,omitempty"`
	SwappedAt    *time.Time `json:"swapped_at,omitempty"`
	SwapCount    *int       `json:"swap_count,omitempty"`
}

// ProgressReader wraps an io.Reader and reports progress
type ProgressReader struct {
	reader      io.Reader
	total       int64
	read        int64
	lastPercent int
	callback    func(read int64, total int64, percent int)
}

// NewProgressReader creates a new progress tracking reader
func NewProgressReader(r io.Reader, total int64, callback func(int64, int64, int)) *ProgressReader {
	return &ProgressReader{
		reader:   r,
		total:    total,
		callback: callback,
	}
}

// Read implements io.Reader interface
func (pr *ProgressReader) Read(p []byte) (int, error) {
	n, err := pr.reader.Read(p)
	pr.read += int64(n)

	// Calculate percentage
	percent := int(float64(pr.read) / float64(pr.total) * 100)

	// Only report if percentage changed (avoid spam)
	if percent != pr.lastPercent {
		pr.lastPercent = percent
		if pr.callback != nil {
			pr.callback(pr.read, pr.total, percent)
		}
	}

	return n, err
}

// printProgress displays upload progress to stdout
func printProgress(read int64, total int64, percent int) {
	// Convert to human-readable format
	readMB := float64(read) / (1024 * 1024)
	totalMB := float64(total) / (1024 * 1024)

	// Create progress bar (50 chars wide)
	barWidth := 50
	filled := int(float64(barWidth) * float64(percent) / 100)
	bar := strings.Repeat("=", filled) + strings.Repeat("-", barWidth-filled)

	// Print with carriage return to overwrite previous line
	fmt.Printf("\rUploading: [%s] %d%% (%.2f MB / %.2f MB)", bar, percent, readMB, totalMB)

	// Add newline when complete
	if percent >= 100 {
		fmt.Println()
	}
}

// isOSImage checks if a file is an OS image based on its extension
func isOSImage(filename string) bool {
	ext := strings.ToLower(filepath.Ext(filename))
	result := ext == ".img" || ext == ".wic" || ext == ".sdimg" || ext == ".zip" || ext == ".tgz" || ext == ".xz" || ext == ".zst" || ext == ".mender"
	log.WithFields(logrus.Fields{
		"filename":  filename,
		"extension": ext,
		"is_image":  result,
	}).Info("Checking if file is an OS image")
	return result
}

// validateDeviceType checks if the device type is valid
func validateDeviceType(deviceType string) error {
	if deviceType == "" {
		return fmt.Errorf("device type cannot be empty")
	}
	if len(deviceType) > maxDeviceTypeLength {
		return fmt.Errorf("device type is too long (max %d characters)", maxDeviceTypeLength)
	}
	// Check for invalid characters that could break path parsing
	invalidChars := []string{"/", "\\", "..", "\x00", "\n", "\r"}
	for _, char := range invalidChars {
		if strings.Contains(deviceType, char) {
			return fmt.Errorf("device type contains invalid character: %q", char)
		}
	}
	return nil
}

// validateVersion checks if the version is valid
func validateVersion(version string) error {
	if version == "" {
		return fmt.Errorf("version cannot be empty")
	}
	if len(version) > maxVersionLength {
		return fmt.Errorf("version is too long (max %d characters)", maxVersionLength)
	}
	// Check for invalid characters that could break path parsing
	invalidChars := []string{"/", "\\", "..", "\x00", "\n", "\r"}
	for _, char := range invalidChars {
		if strings.Contains(version, char) {
			return fmt.Errorf("version contains invalid character: %q", char)
		}
	}
	return nil
}

// validateFileExists checks if the file exists and is readable
func validateFileExists(filePath string) error {
	if filePath == "" {
		return fmt.Errorf("file path cannot be empty")
	}
	info, err := os.Stat(filePath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("file does not exist: %s", filePath)
		}
		return fmt.Errorf("cannot access file: %w", err)
	}
	if info.IsDir() {
		return fmt.Errorf("path is a directory, not a file: %s", filePath)
	}
	if info.Size() == 0 {
		return fmt.Errorf("file is empty: %s", filePath)
	}
	return nil
}

// validateStability checks if the stability value is valid
func validateStability(stability string) error {
	if stability == "" {
		// Empty is allowed, defaults to stable
		return nil
	}
	validStabilities := []string{"stable", "experimental", "deprecated"}
	for _, valid := range validStabilities {
		if stability == valid {
			return nil
		}
	}
	return fmt.Errorf("invalid stability value: %s (must be one of: stable, experimental, deprecated)", stability)
}

// DiscordEmbed represents an embed in a Discord message
type DiscordEmbed struct {
	Title       string              `json:"title,omitempty"`
	Description string              `json:"description,omitempty"`
	Color       int                 `json:"color,omitempty"`
	Fields      []DiscordEmbedField `json:"fields,omitempty"`
	Timestamp   string              `json:"timestamp,omitempty"`
}

// DiscordEmbedField represents a field in a Discord embed
type DiscordEmbedField struct {
	Name   string `json:"name"`
	Value  string `json:"value"`
	Inline bool   `json:"inline"`
}

// DiscordWebhookPayload represents the payload sent to Discord
type DiscordWebhookPayload struct {
	Content string         `json:"content,omitempty"`
	Embeds  []DiscordEmbed `json:"embeds,omitempty"`
}

// fileProcessResult holds the result of processing a file (compression + checksum)
type fileProcessResult struct {
	compressedPath string
	checksum       string
	err            error
}

// processFileAsync compresses and calculates checksum concurrently
// fileType: "os" (from --file), "ota" (from --ota-update), "recovery" (from --recovery-file)
func processFileAsync(ctx context.Context, filePath string, fileType string) <-chan fileProcessResult {
	resultChan := make(chan fileProcessResult, 1)

	go func() {
		defer close(resultChan)

		// Check if context was cancelled
		select {
		case <-ctx.Done():
			resultChan <- fileProcessResult{err: ctx.Err()}
			return
		default:
		}

		// Compress file if needed
		compressedPath, err := compressFile(ctx, filePath, fileType)
		if err != nil {
			resultChan <- fileProcessResult{err: fmt.Errorf("compression failed: %w", err)}
			return
		}

		// Check cancellation again before checksum
		select {
		case <-ctx.Done():
			resultChan <- fileProcessResult{err: ctx.Err()}
			return
		default:
		}

		// Calculate checksum
		checksum, err := calculateChecksum(compressedPath)
		if err != nil {
			resultChan <- fileProcessResult{err: fmt.Errorf("checksum calculation failed: %w", err)}
			return
		}

		resultChan <- fileProcessResult{
			compressedPath: compressedPath,
			checksum:       checksum,
		}
	}()

	return resultChan
}

// uploadResult holds the result of an upload operation
type uploadResult struct {
	path string
	size int64
	err  error
}

// uploadFileAsync uploads a file asynchronously
func uploadFileAsync(ctx context.Context, bucket *storage.BucketHandle, localPath, deviceType, version string) <-chan uploadResult {
	resultChan := make(chan uploadResult, 1)

	go func() {
		defer close(resultChan)

		// Stat the local file before uploading so we can verify the upload completed fully
		localInfo, err := os.Stat(localPath)
		if err != nil {
			resultChan <- uploadResult{err: fmt.Errorf("failed to stat local file: %w", err)}
			return
		}
		expectedSize := localInfo.Size()

		path, err := uploadFile(ctx, bucket, localPath, deviceType, version)
		if err != nil {
			resultChan <- uploadResult{err: err}
			return
		}

		// Get file size from GCS and verify it matches the local file.
		// A mismatch indicates a silent truncation (e.g. auth token expired mid-upload).
		obj := bucket.Object(path)
		attrs, err := obj.Attrs(ctx)
		if err != nil {
			resultChan <- uploadResult{err: fmt.Errorf("failed to get file attributes: %w", err)}
			return
		}

		if attrs.Size != expectedSize {
			resultChan <- uploadResult{err: fmt.Errorf("upload truncated: GCS object is %d bytes but local file is %d bytes (token may have expired mid-upload)", attrs.Size, expectedSize)}
			return
		}

		resultChan <- uploadResult{
			path: path,
			size: attrs.Size,
		}
	}()

	return resultChan
}

// calculateChecksum calculates the SHA256 checksum of a file
func calculateChecksum(filePath string) (string, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return "", fmt.Errorf("failed to open file for checksum: %w", err)
	}
	defer file.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", fmt.Errorf("failed to calculate checksum: %w", err)
	}

	checksum := hex.EncodeToString(hash.Sum(nil))
	log.WithFields(logrus.Fields{
		"file":     filePath,
		"checksum": checksum,
	}).Debug("Calculated SHA256 checksum")

	return checksum, nil
}

// isAlreadyCompressed checks if a file is already compressed based on its extension
func isAlreadyCompressed(filename string) bool {
	// Get the full extension (handles .tar.gz, .tar.xz, etc.)
	lowerName := strings.ToLower(filename)

	// Common compressed formats
	compressedExts := []string{
		".xz", ".gz", ".bz2", ".zst", ".lz4", ".lzma",
		".tar.gz", ".tgz", ".tar.xz", ".tar.zst", ".tar.bz2",
		".zip", ".7z", ".rar",
		".mender", // Mender Artifacts are tar containers with internally xz-compressed payloads
	}

	for _, ext := range compressedExts {
		if strings.HasSuffix(lowerName, ext) {
			log.WithFields(logrus.Fields{
				"filename":  filename,
				"extension": ext,
			}).Info("File is already compressed, skipping compression")
			return true
		}
	}

	return false
}

// compressFile compresses a file based on its type and compression strategy
// fileType: "os" (OS images from --file), "ota" (OTA updates from --ota-update), "recovery" (recovery files from --recovery-file)
// Returns the path to the compressed file, or the original path if compression not needed
func compressFile(ctx context.Context, inputPath string, fileType string) (string, error) {
	// Check for cancellation before starting
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	default:
	}

	// Skip compression if file is already compressed
	if isAlreadyCompressed(inputPath) {
		return inputPath, nil
	}

	// Resolve symlinks before compression — Yocto deploy directories use
	// chains of versioned symlinks for build artifacts, and the compressor
	// will hit ELOOP if it tries to follow them itself.
	realPath, err := filepath.EvalSymlinks(inputPath)
	if err != nil {
		return "", fmt.Errorf("failed to resolve symlinks for %s: %w", inputPath, err)
	}
	inputPath = realPath

	ext := strings.ToLower(filepath.Ext(inputPath))

	// Determine if file should be compressed based on extension and type
	shouldCompress := false
	compressionMethod := ""

	switch ext {
	case ".img", ".wic", ".sdimg":
		// Raw disk images should be compressed
		shouldCompress = true
		if fileType == "ota" {
			compressionMethod = "xz-max" // Maximum compression for OTA
		} else if fileType == "recovery" {
			compressionMethod = "xz-fast" // Fast compression for recovery (frequently accessed)
		} else {
			// Seekable-zstd for OS images. This single artifact IS the image the
			// wendy CLI flashes: the fast path streams it as .zst + bmap, and the
			// full-image fallback (--no-bmap, `wendy os download`) reads the same
			// object by content-sniffing the zstd magic. It doubles as the
			// manifest .zst artifact, so it is produced once here rather than a
			// gzip .img.gz plus a separate seekable pass over the same 60+ GB
			// image. Done in-process, so the publisher host needs no `zip` binary.
			//
			// Only raw images reach this branch: Raspberry Pi .sdimg is gzipped
			// by the build workflow before upload (isAlreadyCompressed short-
			// circuits it), and eMMC/Thor ship a recovery bundle, not an .img.
			compressionMethod = "seekable-zstd"
		}
	default:
		// Other file types - don't compress
		log.WithFields(logrus.Fields{
			"path": inputPath,
			"ext":  ext,
			"type": fileType,
		}).Info("File type doesn't need compression, using as-is")
		return inputPath, nil
	}

	if !shouldCompress {
		log.WithField("path", inputPath).Info("File doesn't need compression, using as-is")
		return inputPath, nil
	}

	// Get file size for progress calculation
	fileInfo, err := os.Stat(inputPath)
	if err != nil {
		return "", fmt.Errorf("failed to stat file: %w", err)
	}
	fileSize := fileInfo.Size()

	// Determine output path based on compression method
	var outputPath string
	switch compressionMethod {
	case "xz-max", "xz-fast":
		outputPath = inputPath + ".xz"
	case "seekable-zstd":
		outputPath = inputPath + ".zst"
	default:
		return "", fmt.Errorf("unknown compression method: %s", compressionMethod)
	}

	// Check if compressed file already exists
	if _, err := os.Stat(outputPath); err == nil {
		log.WithField("path", outputPath).Info("Compressed file already exists, using existing file")
		return outputPath, nil
	}

	log.WithFields(logrus.Fields{
		"input":     inputPath,
		"output":    outputPath,
		"size":      fileSize,
		"method":    compressionMethod,
		"file_type": fileType,
	}).Info("Compressing file...")

	var cmd *exec.Cmd
	var outFile *os.File       // Declare at function scope for proper cleanup
	var cmdAlreadyStarted bool // Track if cmd.Start() was already called
	var pvCommand *exec.Cmd    // For cleanup when using pv pipeline

	// Handle different compression methods
	switch compressionMethod {
	case "xz-max", "xz-fast":
		// Use xz compression (with or without pv for progress)
		xzFlags := "-9e" // Maximum compression by default
		if compressionMethod == "xz-fast" {
			xzFlags = "-1" // Fast compression for recovery files
		}

		// Check if pv is available for progress
		pvCheckCmd := exec.CommandContext(ctx, "which", "pv")
		hasPv := pvCheckCmd.Run() == nil

		if hasPv {
			// Use pv for progress indication with proper piping (no shell)
			log.Info("Using pv for progress indication")

			// Create the pv command
			pvCommand = exec.CommandContext(ctx, "pv", inputPath)

			// Create the xz command with appropriate flags
			xzCommand := exec.CommandContext(ctx, "xz", xzFlags)

			// Set up pipe: pv stdout -> xz stdin
			var err error
			xzCommand.Stdin, err = pvCommand.StdoutPipe()
			if err != nil {
				return "", fmt.Errorf("failed to create pipe: %w", err)
			}

			// Create output file for xz
			outFile, err = os.Create(outputPath)
			if err != nil {
				return "", fmt.Errorf("failed to create output file: %w", err)
			}

			// Connect xz stdout to output file
			xzCommand.Stdout = outFile
			xzCommand.Stderr = os.Stderr
			pvCommand.Stderr = os.Stderr

			// Start both commands
			if err := xzCommand.Start(); err != nil {
				outFile.Close()
				return "", fmt.Errorf("failed to start xz: %w", err)
			}
			if err := pvCommand.Start(); err != nil {
				xzCommand.Process.Kill()
				xzCommand.Wait() // Wait to reap the zombie process
				outFile.Close()
				return "", fmt.Errorf("failed to start pv: %w", err)
			}

			// Use xz command as the main cmd for Wait() below
			cmd = xzCommand
			cmdAlreadyStarted = true
		} else {
			// Fallback to xz with verbose mode (no pv)
			log.Info("pv not found, using xz verbose mode")
			cmd = exec.CommandContext(ctx, "xz", xzFlags, "-v", "-k", "-c", inputPath)
			var err error
			outFile, err = os.Create(outputPath)
			if err != nil {
				return "", fmt.Errorf("failed to create output file: %w", err)
			}
			cmd.Stdout = outFile
			cmd.Stderr = os.Stderr
		}

	case "seekable-zstd":
		// Produce the seekable-zstd image in-process — no external binary
		// required. Frames are independently decompressible, so the CLI can
		// random-access via bmap; the whole file also decodes as a normal zstd
		// stream for the full-image fallback. Handle everything here and return,
		// since the process-based machinery below is xz-only.
		if err := compressSeekableZstd(inputPath, outputPath); err != nil {
			if rmErr := os.Remove(outputPath); rmErr != nil && !os.IsNotExist(rmErr) {
				log.WithError(rmErr).Warn("Failed to clean up partial compressed file")
			}
			return "", err
		}

		compressedInfo, err := os.Stat(outputPath)
		if err != nil {
			return "", fmt.Errorf("compressed file not found: %w", err)
		}
		if fileSize == 0 {
			return "", fmt.Errorf("original file has zero size")
		}
		compressionRatio := float64(fileSize-compressedInfo.Size()) / float64(fileSize) * 100
		log.WithFields(logrus.Fields{
			"original_size":   fileSize,
			"compressed_size": compressedInfo.Size(),
			"saved":           fmt.Sprintf("%.1f%%", compressionRatio),
		}).Info("Compression complete")
		return outputPath, nil

	default:
		return "", fmt.Errorf("unsupported compression method: %s", compressionMethod)
	}

	// Ensure outFile is closed when function returns
	defer func() {
		if outFile != nil {
			if err := outFile.Close(); err != nil {
				log.WithError(err).Error("Failed to close output file")
			}
		}
	}()

	// Start the compression process (already started if using pv pipeline)
	if !cmdAlreadyStarted {
		if err := cmd.Start(); err != nil {
			return "", fmt.Errorf("failed to start compression: %w", err)
		}
	}

	// Wait for completion or cancellation
	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	select {
	case <-ctx.Done():
		// Context cancelled, kill the processes
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
		if pvCommand != nil && pvCommand.Process != nil {
			pvCommand.Process.Kill()
		}
		// Wait for goroutine to complete to avoid leak
		<-done
		// Also wait for pv if it's running
		if pvCommand != nil {
			pvCommand.Wait()
		}
		// Give process time to release file handles
		time.Sleep(100 * time.Millisecond)
		// Clean up partial file, ignore error if file doesn't exist
		if err := os.Remove(outputPath); err != nil && !os.IsNotExist(err) {
			log.WithError(err).Warn("Failed to clean up partial compressed file")
		}
		return "", ctx.Err()
	case err := <-done:
		// Also wait for pv if it's running
		if pvCommand != nil {
			if pvErr := pvCommand.Wait(); pvErr != nil {
				log.WithError(pvErr).Warn("pv command failed")
			}
		}
		if err != nil {
			// Clean up partial file on failure
			if rmErr := os.Remove(outputPath); rmErr != nil && !os.IsNotExist(rmErr) {
				log.WithError(rmErr).Warn("Failed to clean up partial compressed file")
			}
			return "", fmt.Errorf("compression failed: %w", err)
		}
	}

	// Verify compressed file exists and get its size
	compressedInfo, err := os.Stat(outputPath)
	if err != nil {
		return "", fmt.Errorf("compressed file not found: %w", err)
	}

	// Protect against division by zero
	if fileSize == 0 {
		return "", fmt.Errorf("original file has zero size")
	}

	compressionRatio := float64(fileSize-compressedInfo.Size()) / float64(fileSize) * 100

	log.WithFields(logrus.Fields{
		"original_size":   fileSize,
		"compressed_size": compressedInfo.Size(),
		"saved":           fmt.Sprintf("%.1f%%", compressionRatio),
	}).Info("Compression complete")

	return outputPath, nil
}

// sendDiscordNotification sends a notification to Discord about the update
func sendDiscordNotification(webhookURL string, deviceType, version string, isNightly bool, osSize int64, otaSize int64, recoverySize int64) error {
	if webhookURL == "" {
		return fmt.Errorf("Discord webhook URL is not set")
	}
	buildType := "Stable"
	color := colorStable
	if isNightly {
		buildType = "Nightly"
		color = colorNightly
	}

	// Format OS image size
	osSizeStr := fmt.Sprintf("%.2f MB", float64(osSize)/(1024*1024))

	// Calculate total size
	totalSize := osSize
	if otaSize > 0 {
		totalSize += otaSize
	}
	if recoverySize > 0 {
		totalSize += recoverySize
	}
	totalSizeStr := fmt.Sprintf("%.2f MB", float64(totalSize)/(1024*1024))

	// Build components list
	components := []string{"📦 OS Image"}
	if otaSize > 0 {
		components = append(components, "🔄 OTA Update")
	}
	if recoverySize > 0 {
		components = append(components, "🔧 Recovery File")
	}
	componentsStr := strings.Join(components, "\n")

	// Build fields dynamically
	fields := []DiscordEmbedField{
		{
			Name:   "Device",
			Value:  deviceType,
			Inline: true,
		},
		{
			Name:   "Version",
			Value:  version,
			Inline: true,
		},
		{
			Name:   "Build Type",
			Value:  buildType,
			Inline: true,
		},
		{
			Name:   "Components Updated",
			Value:  componentsStr,
			Inline: false,
		},
		{
			Name:   "OS Image Size",
			Value:  osSizeStr,
			Inline: true,
		},
	}

	// Add OTA size field if provided
	if otaSize > 0 {
		otaSizeStr := fmt.Sprintf("%.2f MB", float64(otaSize)/(1024*1024))
		fields = append(fields, DiscordEmbedField{
			Name:   "OTA Update Size",
			Value:  otaSizeStr,
			Inline: true,
		})
	}

	// Add Recovery size field if provided
	if recoverySize > 0 {
		recoverySizeStr := fmt.Sprintf("%.2f MB", float64(recoverySize)/(1024*1024))
		fields = append(fields, DiscordEmbedField{
			Name:   "Recovery File Size",
			Value:  recoverySizeStr,
			Inline: true,
		})
	}

	// Add total size
	fields = append(fields, DiscordEmbedField{
		Name:   "Total Size",
		Value:  totalSizeStr,
		Inline: true,
	})

	// Add status
	fields = append(fields, DiscordEmbedField{
		Name:   "Status",
		Value:  "✅ Successfully Published",
		Inline: false,
	})

	embed := DiscordEmbed{
		Title:       fmt.Sprintf("New %s Build Published", buildType),
		Description: fmt.Sprintf("WendyOS update for **%s** version **%s** has been published", deviceType, version),
		Color:       color,
		Fields:      fields,
		Timestamp:   time.Now().Format(time.RFC3339),
	}

	payload := DiscordWebhookPayload{
		Embeds: []DiscordEmbed{embed},
	}

	jsonData, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("failed to marshal Discord payload: %w", err)
	}

	// Create HTTP client with timeout
	client := &http.Client{
		Timeout: 30 * time.Second,
	}

	resp, err := client.Post(webhookURL, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return fmt.Errorf("failed to send Discord notification: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// Limit response body read to prevent DoS
		limitedBody := io.LimitReader(resp.Body, 1024*1024) // 1MB limit
		body, readErr := io.ReadAll(limitedBody)
		if readErr != nil {
			return fmt.Errorf("Discord API returned status %d (could not read body: %w)", resp.StatusCode, readErr)
		}
		return fmt.Errorf("Discord API returned status %d: %s", resp.StatusCode, string(body))
	}

	log.Info("Discord notification sent successfully")
	return nil
}

// createStorageClientWithAuth creates a storage client and triggers authentication if needed
func createStorageClientWithAuth(ctx context.Context, accessToken string) (*storage.Client, error) {
	// If an access token is provided, seed the refreshing token source with it.
	// GCP access tokens expire after 1 hour; gcloudTokenSource re-runs
	// "gcloud auth print-access-token" when the token is near expiry so that
	// long-running retry loops (412 backoff) don't hit 401 mid-flight.
	if accessToken != "" {
		log.Info("Using provided access token for authentication")
		ts := &gcloudTokenSource{
			token: &oauth2.Token{
				AccessToken: accessToken,
				TokenType:   "Bearer",
				Expiry:      time.Now().Add(55 * time.Minute),
			},
		}
		client, err := storage.NewClient(ctx, option.WithTokenSource(ts))
		if err != nil {
			return nil, fmt.Errorf("failed to create storage client with access token: %w", err)
		}
		return client, nil
	}

	// Try to create the client with default credentials
	client, err := storage.NewClient(ctx)
	if err != nil {
		// Check if this is an authentication error
		errMsg := err.Error()
		if strings.Contains(errMsg, "could not find default credentials") ||
			strings.Contains(errMsg, "application default credentials") ||
			strings.Contains(errMsg, "credential") {
			log.Warn("Authentication credentials not found. Triggering gcloud auth...")

			// Run gcloud auth application-default login
			cmd := exec.Command("gcloud", "auth", "application-default", "login")
			cmd.Stdin = os.Stdin
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr

			if err := cmd.Run(); err != nil {
				return nil, fmt.Errorf("authentication failed: %w", err)
			}

			log.Info("Authentication successful. Retrying storage client creation...")

			// Retry creating the client
			client, err = storage.NewClient(ctx)
			if err != nil {
				return nil, fmt.Errorf("failed to create storage client after authentication: %w", err)
			}
		} else {
			return nil, err
		}
	}

	return client, nil
}

func main() {
	// Configure logger
	log.SetFormatter(&logrus.TextFormatter{
		FullTimestamp: true,
	})
	log.SetLevel(logrus.InfoLevel)

	// Parse command line arguments
	bucketName := flag.String("bucket", "wendyos-images-public", "GCS bucket name")
	deviceType := flag.String("device", "", "Device type (e.g., raspberry-pi-5)")
	version := flag.String("version", "", "Version number (e.g., 1.0.0)")
	localFile := flag.String("file", "", "Local file path to upload")
	otaUpdateFile := flag.String("ota-update", "", "Local OTA update file path to upload")
	recoveryFile := flag.String("recovery-file", "", "Optional recovery/tegraflash file path to upload")
	flashpackFile := flag.String("flashpack-file", "", "Optional Thor flashpack (.tar.zst) file path to upload")
	bmapFile := flag.String("bmap-file", "", "Optional .bmap block-map file to upload alongside the OS image")
	sbomFile := flag.String("sbom", "", "Optional SPDX SBOM bundle (.spdx.tar.zst) to upload alongside the OS image and record in the manifest")
	storage := flag.String("storage", "", "Storage type for multi-artifact devices: nvme or sd (omit for single-storage devices)")
	updateOnly := flag.Bool("update-only", false, "Only update manifests without uploading")
	skipMasterManifest := flag.Bool("skip-master-manifest", false, "Skip master manifest update (a separate job will handle it)")
	masterManifestOnly := flag.Bool("master-manifest-only", false, "Only update the master manifest, skip upload and device manifest")
	uploadOnly := flag.Bool("upload-only", false, "Upload files without touching any manifest; requires --metadata-out (a serialised publish job applies the manifest writes later)")
	metadataOut := flag.String("metadata-out", "", "Path to write the manifest-entry JSON produced by --upload-only")
	applyMetadata := flag.String("apply-metadata", "", "Path to a manifest-entry JSON (from --upload-only); updates the device manifest from it without uploading")
	listImages := flag.Bool("list", false, "List all images in the bucket")
	createDevice := flag.Bool("create-device", false, "Create a new device type in the manifest")
	nightly := flag.Bool("nightly", false, "Mark this build as a nightly/untested build")
	stability := flag.String("stability", "stable", "Device stability level: stable, experimental, deprecated")
	notifyDiscord := flag.Bool("notify-discord", true, "Send Discord notification after successful publish")
	notifyOnly := flag.Bool("notify-only", false, "Send Discord notification for an already-published release (reads sizes from manifest)")
	accessToken := flag.String("access-token", "", "GCS access token (from gcloud auth print-access-token)")
	debug := flag.Bool("debug", false, "Enable debug logging")
	promote := flag.Bool("promote", false, "Promote nightly to stable by removing 'nightly' from version name")
	swap := flag.Bool("swap", false, "Replace existing version's image file while preserving metadata")
	firmware := flag.Bool("firmware", false, "Upload firmware (.bin) instead of OS image")
	chip := flag.String("chip", "", "Chip type for firmware upload (e.g., esp32-s3)")
	removeDevice := flag.Bool("remove-device", false, "Remove a device (or firmware chip with --firmware) and all its images/versions")
	removeKeepFiles := flag.Bool("remove-keep-files", false, "When removing a device, keep uploaded files in the bucket (only remove from manifests)")
	renameTo := flag.String("rename-to", "", "Rename a device (--device old --rename-to new) by moving all files and updating manifests")
	flag.Parse()

	if *debug {
		log.SetLevel(logrus.DebugLevel)
	}

	// Validate args
	if *listImages {
		// No other args needed for listing
	} else if *notifyOnly {
		// For notify-only, we need device type and version
		if err := validateDeviceType(*deviceType); err != nil {
			log.WithError(err).Fatal("Invalid device type")
		}
		if err := validateVersion(*version); err != nil {
			log.WithError(err).Fatal("Invalid version")
		}
	} else if *renameTo != "" {
		// For renaming a device, we need source and target
		if err := validateDeviceType(*deviceType); err != nil {
			log.WithError(err).Fatal("Invalid source device type")
		}
		if err := validateDeviceType(*renameTo); err != nil {
			log.WithError(err).Fatal("Invalid target device type (--rename-to)")
		}
		if *deviceType == *renameTo {
			log.Fatal("Source and target device types are the same")
		}
	} else if *removeDevice && *firmware {
		// For removing a firmware chip, we need the chip type
		if err := validateDeviceType(*chip); err != nil {
			log.WithError(err).Fatal("Invalid chip type")
		}
	} else if *removeDevice {
		// For removing a device, we need the device type
		if err := validateDeviceType(*deviceType); err != nil {
			log.WithError(err).Fatal("Invalid device type")
		}
	} else if *firmware && *createDevice {
		// For creating a firmware chip, we need the chip type
		if err := validateDeviceType(*chip); err != nil {
			log.WithError(err).Fatal("Invalid chip type")
		}
	} else if *firmware {
		// For firmware upload, we need chip, version, and file
		if err := validateDeviceType(*chip); err != nil {
			log.WithError(err).Fatal("Invalid chip type")
		}
		if err := validateVersion(*version); err != nil {
			log.WithError(err).Fatal("Invalid version")
		}
		if err := validateFileExists(*localFile); err != nil {
			log.WithError(err).Fatal("Invalid firmware file")
		}
		if *otaUpdateFile != "" {
			log.Fatal("--ota-update is not supported for firmware uploads")
		}
		if *recoveryFile != "" {
			log.Fatal("--recovery-file is not supported for firmware uploads")
		}
		if *flashpackFile != "" {
			log.Fatal("--flashpack-file is not supported for firmware uploads")
		}
		if *sbomFile != "" {
			log.Fatal("--sbom is not supported for firmware uploads")
		}
	} else if *createDevice {
		// For creating a device, we only need the device type
		if err := validateDeviceType(*deviceType); err != nil {
			log.WithError(err).Fatal("Invalid device type")
		}
		if err := validateStability(*stability); err != nil {
			log.WithError(err).Fatal("Invalid stability")
		}
	} else if *promote {
		// For promotion, we need device type and version
		if err := validateDeviceType(*deviceType); err != nil {
			log.WithError(err).Fatal("Invalid device type")
		}
		if err := validateVersion(*version); err != nil {
			log.WithError(err).Fatal("Invalid source version")
		}
	} else if *swap {
		// For swap, we need device type, version, and file
		if err := validateDeviceType(*deviceType); err != nil {
			log.WithError(err).Fatal("Invalid device type")
		}
		if err := validateVersion(*version); err != nil {
			log.WithError(err).Fatal("Invalid version")
		}
		if err := validateFileExists(*localFile); err != nil {
			log.WithError(err).Fatal("Invalid file")
		}
	} else if *applyMetadata != "" {
		// For applying a manifest entry, the file must exist; everything else
		// (device, version, paths) is validated from the entry content.
		if err := validateFileExists(*applyMetadata); err != nil {
			log.WithError(err).Fatal("Invalid --apply-metadata file")
		}
	} else {
		// For normal operations, we need device type and version
		if err := validateDeviceType(*deviceType); err != nil {
			log.WithError(err).Fatal("Invalid device type")
		}
		if err := validateVersion(*version); err != nil {
			log.WithError(err).Fatal("Invalid version")
		}
		if err := validateStability(*stability); err != nil {
			log.WithError(err).Fatal("Invalid stability")
		}
		if *storage != "" && *storage != "nvme" && *storage != "sd" && *storage != "emmc" {
			log.Fatalf("Invalid --storage value %q: must be nvme, sd, or emmc", *storage)
		}
		if *uploadOnly {
			if *metadataOut == "" {
				log.Fatal("--upload-only requires --metadata-out")
			}
			if *updateOnly || *masterManifestOnly {
				log.Fatal("--upload-only cannot be combined with --update-only or --master-manifest-only")
			}
		}
		if !*updateOnly && !*masterManifestOnly {
			// At least one file (main, OTA, or recovery) must be provided
			if *localFile == "" && *otaUpdateFile == "" && *recoveryFile == "" {
				log.Fatal("At least one file must be provided: use --file for OS image, --ota-update for OTA update, or --recovery-file for recovery file")
			}

			// Validate main file if provided
			if *localFile != "" {
				if err := validateFileExists(*localFile); err != nil {
					log.WithError(err).Fatal("Invalid main file")
				}
			}

			// Validate OTA update file if provided
			if *otaUpdateFile != "" {
				if err := validateFileExists(*otaUpdateFile); err != nil {
					log.WithError(err).Fatal("Invalid OTA update file")
				}
			}

			// Validate recovery file if provided
			if *recoveryFile != "" {
				if err := validateFileExists(*recoveryFile); err != nil {
					log.WithError(err).Fatal("Invalid recovery file")
				}
			}

			// Validate flashpack file if provided
			if *flashpackFile != "" {
				if err := validateFileExists(*flashpackFile); err != nil {
					log.WithError(err).Fatal("Invalid flashpack file")
				}
			}

			// Validate bmap file if provided
			if *bmapFile != "" {
				if err := validateFileExists(*bmapFile); err != nil {
					log.WithError(err).Fatal("Invalid bmap file")
				}
			}

			// Validate SBOM file if provided
			if *sbomFile != "" {
				if err := validateFileExists(*sbomFile); err != nil {
					log.WithError(err).Fatal("Invalid SBOM file")
				}
			}
		}
	}

	// Create context with timeout and storage client
	// 30 minute timeout should be sufficient for most uploads
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()

	client, err := createStorageClientWithAuth(ctx, *accessToken)
	if err != nil {
		log.WithError(err).Fatal("Failed to create storage client")
	}
	defer client.Close()

	bucket := client.Bucket(*bucketName)

	// List images if requested
	if *listImages {
		listImagesInBucket(ctx, bucket)
		return
	}

	// Send notification for an already-published release
	if *notifyOnly {
		manifestPath := fmt.Sprintf("manifests/%s.json", *deviceType)
		r, err := bucket.Object(manifestPath).NewReader(ctx)
		if err != nil {
			log.WithError(err).Fatal("Failed to read device manifest")
		}
		content, err := io.ReadAll(io.LimitReader(r, 10*1024*1024))
		r.Close()
		if err != nil {
			log.WithError(err).Fatal("Failed to read device manifest content")
		}
		var manifest DeviceManifest
		if err := json.Unmarshal(content, &manifest); err != nil {
			log.WithError(err).Fatal("Failed to parse device manifest")
		}
		versionMeta, exists := manifest.Versions[*version]
		if !exists {
			log.Fatalf("Version %s not found in manifest for device %s", *version, *deviceType)
		}
		if err := sendDiscordNotification(discordWebhookURL, *deviceType, *version, versionMeta.IsNightly, versionMeta.SizeBytes, versionMeta.OTAUpdateSizeBytes, versionMeta.RecoverySizeBytes); err != nil {
			log.WithError(err).Fatal("Failed to send Discord notification")
		}
		log.Info("Discord notification sent successfully")
		return
	}

	// Update only the master manifest (used by a serialised publish job after parallel builds)
	if *masterManifestOnly {
		logger := log.WithFields(logrus.Fields{
			"device_type": *deviceType,
			"version":     *version,
			"is_nightly":  *nightly,
			"stability":   *stability,
		})
		if err := updateMasterManifest(ctx, logger, bucket, *deviceType, *version, *nightly, *stability, true); err != nil {
			log.WithError(err).Fatal("Failed to update master manifest")
		}
		return
	}

	// Apply a manifest entry produced by --upload-only (used by the serialised
	// publish job after parallel builds). Only the device manifest is written;
	// the publish job updates the master manifest separately via
	// --master-manifest-only once all entries have been applied.
	if *applyMetadata != "" {
		entry, err := readManifestEntry(*applyMetadata)
		if err != nil {
			log.WithError(err).Fatal("Failed to read manifest entry")
		}
		log.WithFields(logrus.Fields{
			"entry":   *applyMetadata,
			"device":  entry.Device,
			"version": entry.Version,
			"storage": entry.Storage,
		}).Info("Applying manifest entry")
		updateManifests(
			ctx, bucket, entry.Device, entry.Version,
			entry.FilePath, entry.FileSize, entry.FileChecksum,
			entry.BmapPath,
			entry.ZstPath, entry.ZstChecksum, entry.ZstSize,
			entry.OTAUpdatePath, entry.OTAUpdateSize, entry.OTAUpdateChecksum,
			entry.RecoveryPath, entry.RecoverySize, entry.RecoveryChecksum,
			entry.FlashpackPath, entry.FlashpackSize, entry.FlashpackChecksum,
			entry.SBOMPath, entry.SBOMSize, entry.SBOMChecksum,
			entry.Storage, entry.Nightly, entry.Stability, *notifyDiscord, true,
		)
		return
	}

	// Rename device if requested
	if *renameTo != "" {
		if err := renameDeviceType(ctx, bucket, *deviceType, *renameTo); err != nil {
			log.WithError(err).Fatal("Failed to rename device")
		}
		return
	}

	// Remove firmware chip if requested
	if *removeDevice && *firmware {
		if err := removeFirmwareChip(ctx, bucket, *chip, !*removeKeepFiles); err != nil {
			log.WithError(err).Fatal("Failed to remove firmware chip")
		}
		return
	}

	// Remove device if requested
	if *removeDevice {
		if err := removeDeviceType(ctx, bucket, *deviceType, !*removeKeepFiles); err != nil {
			log.WithError(err).Fatal("Failed to remove device")
		}
		return
	}

	// Create firmware chip if requested
	if *firmware && *createDevice {
		if err := createNewFirmwareChip(ctx, bucket, *chip); err != nil {
			log.WithError(err).Fatal("Failed to create firmware chip")
		}
		return
	}

	// Create device if requested
	if *createDevice {
		if err := createNewDevice(ctx, bucket, *deviceType, *stability); err != nil {
			log.WithError(err).Fatal("Failed to create device")
		}
		return
	}

	// Promote nightly to stable if requested
	if *promote {
		promoteNightlyToStable(ctx, bucket, *deviceType, *version, *notifyDiscord)
		return
	}

	// Swap image file if requested
	if *swap {
		swapImageFile(ctx, bucket, *deviceType, *version, *localFile, *recoveryFile, *nightly)
		return
	}

	// Firmware upload flow
	if *firmware {
		log.WithFields(logrus.Fields{
			"chip":    *chip,
			"version": *version,
			"file":    *localFile,
		}).Info("Starting firmware upload")

		// Calculate checksum (no compression for .bin files)
		checksum, err := calculateChecksum(*localFile)
		if err != nil {
			log.WithError(err).Fatal("Failed to calculate firmware checksum")
		}

		// Upload firmware file
		fwPath, err := uploadFirmwareFile(ctx, bucket, *localFile, *chip, *version)
		if err != nil {
			log.WithError(err).Fatal("Failed to upload firmware file")
		}

		// Get file size from GCS attrs
		fwObj := bucket.Object(fwPath)
		fwAttrs, err := fwObj.Attrs(ctx)
		if err != nil {
			log.WithError(err).Fatal("Failed to get firmware file attributes")
		}

		// Update firmware manifests
		updateFirmwareManifests(ctx, bucket, *chip, *version, fwPath, fwAttrs.Size, checksum, *nightly, *notifyDiscord)
		return
	}

	// Process the request
	if !*updateOnly {
		log.Info("Starting parallel file processing...")

		// Process main file if provided
		var mainFileChan <-chan fileProcessResult
		if *localFile != "" {
			log.Info("Processing main OS image...")
			mainFileChan = processFileAsync(ctx, *localFile, "os")
		}

		// Process OTA update file if provided
		var otaUpdateFileChan <-chan fileProcessResult
		if *otaUpdateFile != "" {
			log.Info("Processing OTA update file...")
			otaUpdateFileChan = processFileAsync(ctx, *otaUpdateFile, "ota")
		}

		// Process recovery file if provided
		var recoveryFileChan <-chan fileProcessResult
		if *recoveryFile != "" {
			log.Info("Processing recovery file...")
			recoveryFileChan = processFileAsync(ctx, *recoveryFile, "recovery")
		}

		// Process flashpack file if provided (already .tar.zst — not recompressed)
		var flashpackFileChan <-chan fileProcessResult
		if *flashpackFile != "" {
			log.Info("Processing flashpack file...")
			flashpackFileChan = processFileAsync(ctx, *flashpackFile, "flashpack")
		}

		// Process SBOM file if provided (already .spdx.tar.zst — not recompressed)
		var sbomFileChan <-chan fileProcessResult
		if *sbomFile != "" {
			log.Info("Processing SBOM file...")
			sbomFileChan = processFileAsync(ctx, *sbomFile, "sbom")
		}

		// Wait for main file processing
		var mainResult fileProcessResult
		if mainFileChan != nil {
			mainResult = <-mainFileChan
			if mainResult.err != nil {
				log.WithError(mainResult.err).Fatal("Failed to process main file")
			}
			log.Info("Main file processed successfully")
		}

		// Wait for OTA update file processing
		var otaUpdateResult fileProcessResult
		if otaUpdateFileChan != nil {
			otaUpdateResult = <-otaUpdateFileChan
			if otaUpdateResult.err != nil {
				log.WithError(otaUpdateResult.err).Fatal("Failed to process OTA update file")
			}
			log.Info("OTA update file processed successfully")
		}

		// Wait for recovery file processing
		var recoveryResult fileProcessResult
		if recoveryFileChan != nil {
			recoveryResult = <-recoveryFileChan
			if recoveryResult.err != nil {
				log.WithError(recoveryResult.err).Fatal("Failed to process recovery file")
			}
			log.Info("Recovery file processed successfully")
		}

		// Wait for flashpack file processing
		var flashpackResult fileProcessResult
		if flashpackFileChan != nil {
			flashpackResult = <-flashpackFileChan
			if flashpackResult.err != nil {
				log.WithError(flashpackResult.err).Fatal("Failed to process flashpack file")
			}
			log.Info("Flashpack file processed successfully")
		}

		// Wait for SBOM file processing
		var sbomResult fileProcessResult
		if sbomFileChan != nil {
			sbomResult = <-sbomFileChan
			if sbomResult.err != nil {
				log.WithError(sbomResult.err).Fatal("Failed to process SBOM file")
			}
			log.Info("SBOM file processed successfully")
		}

		// Upload files in parallel
		log.Info("Starting parallel uploads...")

		var mainUploadChan <-chan uploadResult
		if mainResult.compressedPath != "" {
			mainUploadChan = uploadFileAsync(ctx, bucket, mainResult.compressedPath, *deviceType, *version)
		}

		var otaUpdateUploadChan <-chan uploadResult
		if otaUpdateResult.compressedPath != "" {
			otaUpdateUploadChan = uploadFileAsync(ctx, bucket, otaUpdateResult.compressedPath, *deviceType, *version)
		}

		var recoveryUploadChan <-chan uploadResult
		if recoveryResult.compressedPath != "" {
			recoveryUploadChan = uploadFileAsync(ctx, bucket, recoveryResult.compressedPath, *deviceType, *version)
		}

		var flashpackUploadChan <-chan uploadResult
		if flashpackResult.compressedPath != "" {
			flashpackUploadChan = uploadFileAsync(ctx, bucket, flashpackResult.compressedPath, *deviceType, *version)
		}

		var sbomUploadChan <-chan uploadResult
		if sbomResult.compressedPath != "" {
			sbomUploadChan = uploadFileAsync(ctx, bucket, sbomResult.compressedPath, *deviceType, *version)
		}

		// bmap is a small XML file; upload it in parallel with the others.
		var bmapUploadChan <-chan uploadResult
		if *bmapFile != "" {
			bmapUploadChan = uploadFileAsync(ctx, bucket, *bmapFile, *deviceType, *version)
		}

		// The seekable-zstd OS image now IS the main file (compressFile produced
		// it in place of a gzip .img.gz), so there is no separate .zst artifact
		// to generate or upload here — the manifest .zst fields reuse the main
		// upload. See the zst-derivation block after the upload waits.

		// Wait for uploads to complete
		var mainUpload uploadResult
		if mainUploadChan != nil {
			mainUpload = <-mainUploadChan
			if mainUpload.err != nil {
				log.WithError(mainUpload.err).Fatal("Failed to upload main file")
			}
			log.Info("Main file uploaded successfully")
		}

		var otaUpdateUpload uploadResult
		if otaUpdateUploadChan != nil {
			otaUpdateUpload = <-otaUpdateUploadChan
			if otaUpdateUpload.err != nil {
				log.WithError(otaUpdateUpload.err).Fatal("Failed to upload OTA update file")
			}
			log.Info("OTA update file uploaded successfully")
		}

		var recoveryUpload uploadResult
		if recoveryUploadChan != nil {
			recoveryUpload = <-recoveryUploadChan
			if recoveryUpload.err != nil {
				log.WithError(recoveryUpload.err).Fatal("Failed to upload recovery file")
			}
			log.Info("Recovery file uploaded successfully")
		}

		var flashpackUpload uploadResult
		if flashpackUploadChan != nil {
			flashpackUpload = <-flashpackUploadChan
			if flashpackUpload.err != nil {
				log.WithError(flashpackUpload.err).Fatal("Failed to upload flashpack file")
			}
			log.Info("Flashpack file uploaded successfully")
		}

		var bmapUpload uploadResult
		if bmapUploadChan != nil {
			bmapUpload = <-bmapUploadChan
			if bmapUpload.err != nil {
				log.WithError(bmapUpload.err).Fatal("Failed to upload bmap file")
			}
			log.Info("Bmap file uploaded successfully")
		}

		var sbomUpload uploadResult
		if sbomUploadChan != nil {
			sbomUpload = <-sbomUploadChan
			if sbomUpload.err != nil {
				log.WithError(sbomUpload.err).Fatal("Failed to upload SBOM file")
			}
			log.Info("SBOM file uploaded successfully")
		}

		// Seekable-zstd manifest fields. When the main OS image is itself a
		// seekable .zst (Jetson raw .img), it doubles as the .zst artifact, so
		// reuse the single upload rather than a second identical object.
		// Non-.zst main images (RPi .sdimg.gz, eMMC/Thor bundles) have none.
		var zstPath, zstChecksum string
		var zstSize int64
		if strings.HasSuffix(strings.ToLower(mainResult.compressedPath), ".zst") {
			zstPath = mainUpload.path
			zstChecksum = mainResult.checksum
			zstSize = mainUpload.size
		}

		// In upload-only mode the manifests are deliberately untouched: write
		// the entry file for the publish job and stop here.
		if *uploadOnly {
			entry := ManifestEntry{
				Device:            *deviceType,
				Version:           *version,
				Storage:           *storage,
				Nightly:           *nightly,
				Stability:         *stability,
				FilePath:          mainUpload.path,
				FileSize:          mainUpload.size,
				FileChecksum:      mainResult.checksum,
				BmapPath:          bmapUpload.path,
				ZstPath:           zstPath,
				ZstChecksum:       zstChecksum,
				ZstSize:           zstSize,
				OTAUpdatePath:     otaUpdateUpload.path,
				OTAUpdateSize:     otaUpdateUpload.size,
				OTAUpdateChecksum: otaUpdateResult.checksum,
				RecoveryPath:      recoveryUpload.path,
				RecoverySize:      recoveryUpload.size,
				RecoveryChecksum:  recoveryResult.checksum,
				FlashpackPath:     flashpackUpload.path,
				FlashpackSize:     flashpackUpload.size,
				FlashpackChecksum: flashpackResult.checksum,
				SBOMPath:          sbomUpload.path,
				SBOMSize:          sbomUpload.size,
				SBOMChecksum:      sbomResult.checksum,
			}
			if err := writeManifestEntry(*metadataOut, entry); err != nil {
				log.WithError(err).Fatal("Failed to write manifest entry")
			}
			log.WithField("path", *metadataOut).Info("Uploads complete; manifest entry written (manifests untouched, --upload-only)")
			return
		}

		// Update manifests with results
		updateManifests(
			ctx, bucket, *deviceType, *version,
			mainUpload.path, mainUpload.size, mainResult.checksum,
			bmapUpload.path,
			zstPath, zstChecksum, zstSize,
			otaUpdateUpload.path, otaUpdateUpload.size, otaUpdateResult.checksum,
			recoveryUpload.path, recoveryUpload.size, recoveryResult.checksum,
			flashpackUpload.path, flashpackUpload.size, flashpackResult.checksum,
			sbomUpload.path, sbomUpload.size, sbomResult.checksum,
			*storage, *nightly, *stability, *notifyDiscord, *skipMasterManifest,
		)
	} else {
		// Just update manifests for existing file
		imagePath := fmt.Sprintf("images/%s/%s/%s", *deviceType, *version, filepath.Base(*localFile))

		obj := bucket.Object(imagePath)
		attrs, err := obj.Attrs(ctx)
		if err != nil {
			log.WithError(err).Error("Failed to get file attributes, does it exist?")
			return
		}

		// For update-only mode, preserve existing checksums from manifest
		// Read existing manifest to get checksums
		var mainChecksum string
		var otaUpdateChecksum string
		var recoveryChecksum string

		manifestPath := fmt.Sprintf("manifests/%s.json", *deviceType)
		manifestObj := bucket.Object(manifestPath)
		r, err := manifestObj.NewReader(ctx)
		if err == nil {
			defer r.Close()
			var manifest DeviceManifest
			// Limit manifest read size to prevent DoS
			limitedReader := io.LimitReader(r, 10*1024*1024) // 10MB limit
			content, readErr := io.ReadAll(limitedReader)
			if readErr == nil && json.Unmarshal(content, &manifest) == nil {
				if vm, exists := manifest.Versions[*version]; exists {
					mainChecksum = vm.Checksum
					otaUpdateChecksum = vm.OTAUpdateChecksum
					recoveryChecksum = vm.RecoveryChecksum
					log.WithFields(logrus.Fields{
						"main_checksum":     mainChecksum,
						"ota_checksum":      otaUpdateChecksum,
						"recovery_checksum": recoveryChecksum,
					}).Info("Preserving existing checksums from manifest")
				} else {
					log.Warn("Version doesn't exist in manifest - checksums will be empty")
				}
			}
		} else {
			log.WithError(err).Warn("Could not read manifest to preserve checksums")
		}

		// Handle existing OTA update file if specified
		var otaUpdatePath string
		var otaUpdateSize int64
		if *otaUpdateFile != "" {
			otaUpdatePath = fmt.Sprintf("images/%s/%s/%s", *deviceType, *version, filepath.Base(*otaUpdateFile))
			menderObj := bucket.Object(otaUpdatePath)
			menderAttrs, err := menderObj.Attrs(ctx)
			if err != nil {
				log.WithError(err).Error("Failed to get OTA update file attributes, does it exist?")
				return
			}
			otaUpdateSize = menderAttrs.Size
		}

		// Handle existing recovery file if specified
		var recoveryPath string
		var recoverySize int64
		if *recoveryFile != "" {
			recoveryPath = fmt.Sprintf("images/%s/%s/%s", *deviceType, *version, filepath.Base(*recoveryFile))
			recoveryObj := bucket.Object(recoveryPath)
			recoveryAttrs, err := recoveryObj.Attrs(ctx)
			if err != nil {
				log.WithError(err).Error("Failed to get recovery file attributes, does it exist?")
				return
			}
			recoverySize = recoveryAttrs.Size
		}

		updateManifests(ctx, bucket, *deviceType, *version, imagePath, attrs.Size, mainChecksum, "", "", "", 0, otaUpdatePath, otaUpdateSize, otaUpdateChecksum, recoveryPath, recoverySize, recoveryChecksum, "", 0, "", "", 0, "", *storage, *nightly, *stability, *notifyDiscord, *skipMasterManifest)
	}
}

func listImagesInBucket(ctx context.Context, bucket *storage.BucketHandle) {
	log.Info("Listing images in bucket...")

	// List all objects with images/ prefix
	it := bucket.Objects(ctx, &storage.Query{Prefix: "images/"})

	deviceImages := make(map[string]map[string][]string)

	for {
		attrs, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			log.WithError(err).Error("Error listing objects")
			return
		}

		if !isOSImage(attrs.Name) {
			continue
		}

		// Parse path: images/{device_type}/{version}/filename
		parts := strings.Split(attrs.Name, "/")
		if len(parts) < 4 {
			continue
		}

		deviceType := parts[1]
		version := parts[2]
		filename := parts[3]

		// Add to our map
		if _, exists := deviceImages[deviceType]; !exists {
			deviceImages[deviceType] = make(map[string][]string)
		}
		if _, exists := deviceImages[deviceType][version]; !exists {
			deviceImages[deviceType][version] = []string{}
		}

		deviceImages[deviceType][version] = append(deviceImages[deviceType][version], filename)
	}

	// Print results
	fmt.Println("Images in bucket:")
	for device, versions := range deviceImages {
		fmt.Printf("- Device: %s\n", device)
		for version, files := range versions {
			fmt.Printf("  - Version: %s\n", version)
			for _, file := range files {
				fmt.Printf("    - %s\n", file)
			}
		}
	}

	// List all objects with firmware/ prefix
	log.Info("Listing firmware in bucket...")
	fwIt := bucket.Objects(ctx, &storage.Query{Prefix: "firmware/"})

	firmwareFiles := make(map[string]map[string][]string)

	for {
		attrs, err := fwIt.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			log.WithError(err).Error("Error listing firmware objects")
			return
		}

		// Parse path: firmware/{chip}/{version}/filename
		parts := strings.Split(attrs.Name, "/")
		if len(parts) < 4 {
			continue
		}

		chipType := parts[1]
		version := parts[2]
		filename := parts[3]

		if _, exists := firmwareFiles[chipType]; !exists {
			firmwareFiles[chipType] = make(map[string][]string)
		}
		if _, exists := firmwareFiles[chipType][version]; !exists {
			firmwareFiles[chipType][version] = []string{}
		}

		firmwareFiles[chipType][version] = append(firmwareFiles[chipType][version], filename)
	}

	if len(firmwareFiles) > 0 {
		fmt.Println("\nFirmware in bucket:")
		for chipType, versions := range firmwareFiles {
			fmt.Printf("- Chip: %s\n", chipType)
			for version, files := range versions {
				fmt.Printf("  - Version: %s\n", version)
				for _, file := range files {
					fmt.Printf("    - %s\n", file)
				}
			}
		}
	}
}

func uploadFile(ctx context.Context, bucket *storage.BucketHandle, localPath, deviceType, version string) (string, error) {
	filename := filepath.Base(localPath)
	destinationPath := fmt.Sprintf("images/%s/%s/%s", deviceType, version, filename)

	// Skip re-upload if the object already exists in GCS with the same size.
	// This makes outer-retry loops (used to survive 412 manifest races when
	// multiple storage variants write the same device manifest concurrently)
	// fast — they skip the multi-minute image upload and go straight to the
	// manifest update, dramatically shrinking the contention window.
	localInfo, err := os.Stat(localPath)
	if err != nil {
		return "", fmt.Errorf("failed to stat local file: %w", err)
	}
	obj := bucket.Object(destinationPath)
	if existingAttrs, err := obj.Attrs(ctx); err == nil && existingAttrs.Size == localInfo.Size() {
		log.WithField("path", destinationPath).Info("File already in GCS with matching size, skipping upload")
		return destinationPath, nil
	}

	log.WithFields(logrus.Fields{
		"local_path":  localPath,
		"destination": destinationPath,
	}).Info("Uploading file")

	// Open the local file
	file, err := os.Open(localPath)
	if err != nil {
		log.WithError(err).Error("Failed to open local file")
		return "", fmt.Errorf("failed to open file %s: %w", localPath, err)
	}
	defer file.Close()

	// Create the destination object writer
	w := obj.NewWriter(ctx)

	// Set content type based on extension
	contentType := "application/octet-stream"
	if strings.HasSuffix(localPath, ".zip") {
		contentType = "application/zip"
	} else if strings.HasSuffix(localPath, ".tgz") || strings.HasSuffix(localPath, ".gz") {
		contentType = "application/gzip"
	} else if strings.HasSuffix(localPath, ".xz") {
		contentType = "application/x-xz"
	} else if strings.HasSuffix(localPath, ".zst") {
		contentType = "application/zstd"
	}
	w.ContentType = contentType

	// Stream the content (efficient for large files)
	if _, err := io.Copy(w, file); err != nil {
		w.Close() // Close without checking error since write already failed
		log.WithError(err).Error("Failed to write to GCS")
		return "", fmt.Errorf("failed to write to GCS: %w", err)
	}

	// Close to commit the write (MUST check error - this is when upload finalizes)
	if err := w.Close(); err != nil {
		fmt.Println() // Clear the progress line
		log.WithError(err).Error("Failed to close GCS writer")
		return "", fmt.Errorf("failed to finalize upload: %w", err)
	}

	log.WithField("path", destinationPath).Info("File uploaded successfully")
	return destinationPath, nil
}

func updateManifests(ctx context.Context, bucket *storage.BucketHandle, deviceType, version, filePath string, fileSize int64, fileChecksum string, bmapPath string, zstPath, zstChecksum string, zstSize int64, otaUpdatePath string, otaUpdateSize int64, otaUpdateChecksum string, recoveryPath string, recoverySize int64, recoveryChecksum string, flashpackPath string, flashpackSize int64, flashpackChecksum string, sbomPath string, sbomSize int64, sbomChecksum string, storage string, isNightly bool, stability string, notifyDiscord bool, skipMasterManifest bool) {
	logger := log.WithFields(logrus.Fields{
		"device_type":     deviceType,
		"version":         version,
		"file_path":       filePath,
		"ota_update_path": otaUpdatePath,
		"recovery_path":   recoveryPath,
		"is_nightly":      isNightly,
		"stability":       stability,
		"notify_discord":  notifyDiscord,
	})

	deviceLogger := log.WithFields(logrus.Fields{
		"device_type":     deviceType,
		"version":         version,
		"file_path":       filePath,
		"ota_update_path": otaUpdatePath,
		"recovery_path":   recoveryPath,
		"is_nightly":      isNightly,
		"stability":       stability,
		"notify_discord":  notifyDiscord,
		"manifest_type":   "device",
	})

	if skipMasterManifest {
		logger.Info("Updating device manifest (master manifest will be updated by a separate publish job)")
		if err := updateDeviceManifest(ctx, deviceLogger, bucket, deviceType, version, filePath, fileSize, fileChecksum, bmapPath, zstPath, zstChecksum, zstSize, otaUpdatePath, otaUpdateSize, otaUpdateChecksum, recoveryPath, recoverySize, recoveryChecksum, flashpackPath, flashpackSize, flashpackChecksum, sbomPath, sbomSize, sbomChecksum, storage, isNightly); err != nil {
			logger.WithError(err).Fatal("Failed to update device manifest")
		}
	} else {
		logger.Info("Updating device and master manifests in parallel")

		masterLogger := log.WithFields(logrus.Fields{
			"device_type":    deviceType,
			"version":        version,
			"is_nightly":     isNightly,
			"stability":      stability,
			"notify_discord": notifyDiscord,
			"manifest_type":  "master",
		})

		var wg sync.WaitGroup
		wg.Add(2)
		deviceErrChan := make(chan error, 1)
		masterErrChan := make(chan error, 1)

		go func() {
			defer wg.Done()
			deviceErrChan <- updateDeviceManifest(ctx, deviceLogger, bucket, deviceType, version, filePath, fileSize, fileChecksum, bmapPath, zstPath, zstChecksum, zstSize, otaUpdatePath, otaUpdateSize, otaUpdateChecksum, recoveryPath, recoverySize, recoveryChecksum, flashpackPath, flashpackSize, flashpackChecksum, sbomPath, sbomSize, sbomChecksum, storage, isNightly)
		}()

		go func() {
			defer wg.Done()
			masterErrChan <- updateMasterManifest(ctx, masterLogger, bucket, deviceType, version, isNightly, stability, false)
		}()

		wg.Wait()
		close(deviceErrChan)
		close(masterErrChan)

		if deviceErr := <-deviceErrChan; deviceErr != nil {
			logger.WithError(deviceErr).Fatal("Failed to update device manifest")
		}
		if masterErr := <-masterErrChan; masterErr != nil {
			logger.WithError(masterErr).Fatal("Failed to update master manifest")
		}
	}

	logger.Info("Manifests updated successfully")

	// Send Discord notification if requested
	if notifyDiscord {
		logger.Info("Sending Discord notification")
		if err := sendDiscordNotification(discordWebhookURL, deviceType, version, isNightly, fileSize, otaUpdateSize, recoverySize); err != nil {
			logger.WithError(err).Warn("Failed to send Discord notification (update was still successful)")
		}
	}
}

// setBmapPath records a block map on the version metadata, tracking the image
// it describes. The top-level BmapPath mirrors the top-level Path (the NVMe
// image on multi-storage devices, per the Path comment) so older CLIs see a
// consistent path/bmap pair: "nvme" always wins it, "sd" only fills it when no
// NVMe image exists yet (an SD-only device), exactly as Path is assigned.
// eMMC ships no offline image, so it has no bmap. An empty bmapPath is a no-op.
func setBmapPath(meta *VersionMetadata, storageType, bmapPath string) {
	if bmapPath == "" {
		return
	}
	switch storageType {
	case "nvme":
		meta.NVMEBmapPath = bmapPath
		meta.BmapPath = bmapPath
	case "sd":
		meta.SDCardBmapPath = bmapPath
		if meta.BmapPath == "" {
			meta.BmapPath = bmapPath
		}
	case "emmc":
		// No offline image for eMMC, hence no block map.
	default:
		meta.BmapPath = bmapPath
	}
}

// applyOTAUpdate records an OTA (Mender) artifact in the version metadata,
// routing NVMe artifacts to the NVMe-specific fields. The NVMe and SD/eMMC
// builds emit distinct .mender artifacts whose embedded device_type differs,
// so they must not share ota_update_path — otherwise whichever variant
// publishes last wins and the other variant's devices reject the artifact
// ("Artifact device type doesn't match"). For "nvme" the artifact also
// populates ota_update_path as a default, but only when it is unset, so a
// single-variant NVMe board still exposes an OTA without clobbering a
// previously published SD/eMMC artifact.
func applyOTAUpdate(meta *VersionMetadata, storageType, otaPath, otaChecksum string, otaSize int64) {
	if otaPath == "" {
		return
	}
	if storageType == "nvme" {
		meta.NVMEOTAUpdatePath = otaPath
		meta.NVMEOTAUpdateChecksum = otaChecksum
		meta.NVMEOTAUpdateSizeBytes = otaSize
		if meta.OTAUpdatePath == "" {
			meta.OTAUpdatePath = otaPath
			meta.OTAUpdateChecksum = otaChecksum
			meta.OTAUpdateSizeBytes = otaSize
		}
		return
	}
	meta.OTAUpdatePath = otaPath
	meta.OTAUpdateChecksum = otaChecksum
	meta.OTAUpdateSizeBytes = otaSize
}

// setZstPath records a seekable-zstd image on the version metadata, mirroring
// setBmapPath's per-storage logic. The top-level ZstPath mirrors the top-level
// Path (NVMe wins, SD fills only when empty, eMMC ships no offline image so it
// has no zst). Unlike bmap, each zst also carries a checksum and size for
// integrity verification. An empty zstPath is a no-op.
func setZstPath(meta *VersionMetadata, storageType, zstPath, zstChecksum string, zstSize int64) {
	if zstPath == "" {
		return
	}
	switch storageType {
	case "nvme":
		meta.NVMEZstPath = zstPath
		meta.NVMEZstChecksum = zstChecksum
		meta.NVMEZstSizeBytes = zstSize
		meta.ZstPath = zstPath
		meta.ZstChecksum = zstChecksum
		meta.ZstSizeBytes = zstSize
	case "sd":
		meta.SDCardZstPath = zstPath
		meta.SDCardZstChecksum = zstChecksum
		meta.SDCardZstSizeBytes = zstSize
		if meta.ZstPath == "" {
			meta.ZstPath = zstPath
			meta.ZstChecksum = zstChecksum
			meta.ZstSizeBytes = zstSize
		}
	case "emmc":
		// No offline image for eMMC, hence no seekable-zstd image.
	default:
		meta.ZstPath = zstPath
		meta.ZstChecksum = zstChecksum
		meta.ZstSizeBytes = zstSize
	}
}

// seekableFrameSize is the uncompressed size of each independent zstd frame
// written by compressSeekableZstd. 4 MiB balances random-access granularity
// against seek-table overhead.
const seekableFrameSize = 4 << 20 // 4 MiB

// compressSeekableZstd writes srcPath as a seekable-zstd file to dstPath.
// Each frame covers seekableFrameSize uncompressed bytes, so the CLI can
// random-access the image without decompressing from the start.
func compressSeekableZstd(srcPath, dstPath string) error {
	in, err := os.Open(srcPath)
	if err != nil {
		return fmt.Errorf("opening image: %w", err)
	}
	defer in.Close()

	out, err := os.Create(dstPath)
	if err != nil {
		return fmt.Errorf("creating zst: %w", err)
	}
	defer out.Close()

	enc, err := zstd.NewWriter(nil)
	if err != nil {
		return err
	}
	defer enc.Close()

	w, err := seekable.NewWriter(out, enc)
	if err != nil {
		return err
	}

	buf := make([]byte, seekableFrameSize)
	for {
		n, rerr := io.ReadFull(in, buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				w.Close()
				return werr
			}
		}
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			break
		}
		if rerr != nil {
			w.Close()
			return rerr
		}
	}

	if err := w.Close(); err != nil {
		return err
	}
	return out.Close()
}

// copyManifestArtifact copies one artifact (image, block map, …) from srcPath
// into the stable version's image directory and returns the new path. It
// returns "" when srcPath is empty, malformed, or the copy fails — the caller
// treats a missing artifact as non-fatal, matching the image-copy behavior.
func copyManifestArtifact(ctx context.Context, logger *logrus.Entry, bucket *storage.BucketHandle, srcPath, deviceType, stableVersion, label string) string {
	if srcPath == "" {
		return ""
	}
	parts := strings.Split(srcPath, "/")
	if len(parts) < 4 {
		return ""
	}
	destPath := fmt.Sprintf("images/%s/%s/%s", deviceType, stableVersion, parts[len(parts)-1])
	if _, err := bucket.Object(destPath).CopierFrom(bucket.Object(srcPath)).Run(ctx); err != nil {
		logger.WithError(err).Warnf("Failed to copy %s, continuing without it", label)
		return ""
	}
	logger.Infof("%s copied successfully", label)
	return destPath
}

func updateDeviceManifest(ctx context.Context, logger *logrus.Entry, bucket *storage.BucketHandle, deviceType, version, filePath string, fileSize int64, fileChecksum string, bmapPath string, zstPath, zstChecksum string, zstSize int64, otaUpdatePath string, otaUpdateSize int64, otaUpdateChecksum string, recoveryPath string, recoverySize int64, recoveryChecksum string, flashpackPath string, flashpackSize int64, flashpackChecksum string, sbomPath string, sbomSize int64, sbomChecksum string, storageType string, isNightly bool) error {
	manifestPath := fmt.Sprintf("manifests/%s.json", deviceType)
	logger = logger.WithField("manifest_path", manifestPath)
	logger.Info("Processing device manifest")

	obj := bucket.Object(manifestPath)

	const maxRetries = 10
	for attempt := 1; attempt <= maxRetries; attempt++ {
		// Read existing manifest or create new one
		var manifest DeviceManifest
		var generation int64 // 0 means object doesn't exist yet
		r, err := obj.NewReader(ctx)
		if err == nil {
			logger.Info("Reading existing device manifest")

			// Read content with size limit to prevent DoS
			limitedReader := io.LimitReader(r, 10*1024*1024) // 10MB limit
			content, err := io.ReadAll(limitedReader)
			generation = r.Attrs.Generation
			r.Close()
			if err != nil {
				logger.WithError(err).Error("Failed to read existing device manifest")
				return fmt.Errorf("failed to read existing device manifest: %w", err)
			}

			// Unmarshal JSON
			if err := json.Unmarshal(content, &manifest); err != nil {
				logger.WithError(err).Error("Failed to decode existing device manifest")
				return fmt.Errorf("failed to decode existing device manifest: %w", err)
			}

			logger.WithField("version_count", len(manifest.Versions)).Info("Read existing manifest")
		} else {
			// Create new manifest if it doesn't exist
			logger.WithError(err).Info("Creating new device manifest as it doesn't exist")
			manifest = DeviceManifest{
				DeviceID: deviceType,
				Versions: make(map[string]VersionMetadata),
			}
		}

		// Check if version already exists with a different IsNightly flag
		if existingVersion, exists := manifest.Versions[version]; exists {
			if existingVersion.IsNightly != isNightly {
				logger.WithFields(logrus.Fields{
					"version":        version,
					"existing_type":  map[bool]string{true: "nightly", false: "stable"}[existingVersion.IsNightly],
					"requested_type": map[bool]string{true: "nightly", false: "stable"}[isNightly],
				}).Fatal("Cannot change build type for existing version - this would corrupt the manifest")
			}
			logger.WithField("version", version).Info("Version already exists, updating metadata")
		}

		// Update version information
		if isNightly {
			// For nightly builds, only update nightly versions' IsLatest
			for k, v := range manifest.Versions {
				if v.IsNightly {
					v.IsLatest = false
					manifest.Versions[k] = v
				}
			}
			logger.WithField("version", version).Info("Setting version as latest nightly")
		} else {
			// For stable builds, only update stable versions' IsLatest
			for k, v := range manifest.Versions {
				if !v.IsNightly {
					v.IsLatest = false
					manifest.Versions[k] = v
				}
			}
			logger.WithField("version", version).Info("Setting version as latest stable")
		}

		// Add or update this version and mark as latest
		// Start with existing metadata if version already exists, otherwise create new
		versionMetadata, exists := manifest.Versions[version]
		if !exists {
			versionMetadata = VersionMetadata{}
			logger.Info("Creating new version entry")
		} else {
			logger.Info("Updating existing version entry")
		}

		// Update release date
		versionMetadata.ReleaseDate = time.Now()
		versionMetadata.IsLatest = true
		versionMetadata.IsNightly = isNightly

		// Update OS image fields only if provided (filePath not empty).
		// When a storage type is specified the image is stored in the
		// type-specific field as well. For "nvme" the legacy Path field is
		// also updated so that older CLI versions continue to work. For "sd"
		// Path is only set when no prior value exists (i.e. this is the first
		// image ever published for this version).
		if filePath != "" {
			switch storageType {
			case "nvme":
				versionMetadata.NVMEPath = filePath
				versionMetadata.NVMEChecksum = fileChecksum
				versionMetadata.NVMESizeBytes = fileSize
				// Also update the legacy Path field for backwards compat.
				versionMetadata.Path = filePath
				versionMetadata.Checksum = fileChecksum
				versionMetadata.SizeBytes = fileSize
				logger.WithFields(logrus.Fields{
					"path": filePath, "size": fileSize, "checksum": fileChecksum,
				}).Info("Updating NVMe image metadata")
			case "sd":
				versionMetadata.SDCardPath = filePath
				versionMetadata.SDCardChecksum = fileChecksum
				versionMetadata.SDCardSizeBytes = fileSize
				// Set the legacy Path only when it has not been set yet (no NVMe image
				// has been published for this version). Once an NVMe image is present,
				// Path must remain pointing to that image for old CLIs.
				if versionMetadata.Path == "" {
					versionMetadata.Path = filePath
					versionMetadata.Checksum = fileChecksum
					versionMetadata.SizeBytes = fileSize
				}
				logger.WithFields(logrus.Fields{
					"path": filePath, "size": fileSize, "checksum": fileChecksum,
				}).Info("Updating SD card image metadata")
			case "emmc":
				versionMetadata.EMMCPath = filePath
				versionMetadata.EMMCChecksum = fileChecksum
				versionMetadata.EMMCSizeBytes = fileSize
				if versionMetadata.Path == "" {
					versionMetadata.Path = filePath
					versionMetadata.Checksum = fileChecksum
					versionMetadata.SizeBytes = fileSize
				}
				logger.WithFields(logrus.Fields{
					"path": filePath, "size": fileSize, "checksum": fileChecksum,
				}).Info("Updating eMMC image metadata")
			default:
				versionMetadata.Path = filePath
				versionMetadata.Checksum = fileChecksum
				versionMetadata.SizeBytes = fileSize
				logger.WithFields(logrus.Fields{
					"path":     filePath,
					"size":     fileSize,
					"checksum": fileChecksum,
				}).Info("Updating OS image metadata")
			}
		}

		// Store the block map in lockstep with the image it describes. A single
		// shared bmap_path would let the last storage variant published clobber
		// it, leaving top-level bmap_path describing a different image than
		// top-level path (the orin-nano NVMe-vs-SD mismatch).
		setBmapPath(&versionMetadata, storageType, bmapPath)
		// Same per-storage routing for the seekable-zstd image.
		setZstPath(&versionMetadata, storageType, zstPath, zstChecksum, zstSize)

		// Update OTA update fields only if provided. NVMe artifacts are routed
		// to the NVMe-specific field so storage variants don't clobber each
		// other (see applyOTAUpdate).
		if otaUpdatePath != "" {
			applyOTAUpdate(&versionMetadata, storageType, otaUpdatePath, otaUpdateChecksum, otaUpdateSize)
			logger.WithFields(logrus.Fields{
				"storage":      storageType,
				"ota_path":     otaUpdatePath,
				"ota_size":     otaUpdateSize,
				"ota_checksum": otaUpdateChecksum,
			}).Info("Updating OTA update metadata")
		}

		// Update recovery fields only if provided
		if recoveryPath != "" {
			versionMetadata.RecoveryPath = recoveryPath
			versionMetadata.RecoveryChecksum = recoveryChecksum
			versionMetadata.RecoverySizeBytes = recoverySize
			logger.WithFields(logrus.Fields{
				"recovery_path":     recoveryPath,
				"recovery_size":     recoverySize,
				"recovery_checksum": recoveryChecksum,
			}).Info("Updating recovery file metadata")
		}

		// Update flashpack fields only if provided
		if flashpackPath != "" {
			versionMetadata.FlashpackPath = flashpackPath
			versionMetadata.FlashpackChecksum = flashpackChecksum
			versionMetadata.FlashpackSizeBytes = flashpackSize
			logger.WithFields(logrus.Fields{
				"flashpack_path":     flashpackPath,
				"flashpack_size":     flashpackSize,
				"flashpack_checksum": flashpackChecksum,
			}).Info("Updating flashpack metadata")
		}

		// Update SBOM fields only if provided. The SBOM describes the OS image
		// contents (identical across storage variants), so it is a single
		// top-level field with last-writer-wins semantics — no per-storage split.
		if sbomPath != "" {
			versionMetadata.SBOMPath = sbomPath
			versionMetadata.SBOMChecksum = sbomChecksum
			versionMetadata.SBOMSizeBytes = sbomSize
			logger.WithFields(logrus.Fields{
				"sbom_path":     sbomPath,
				"sbom_size":     sbomSize,
				"sbom_checksum": sbomChecksum,
			}).Info("Updating SBOM metadata")
		}

		// Validate that at least one file is provided
		if filePath == "" && otaUpdatePath == "" && recoveryPath == "" {
			logger.Error("Cannot create version entry with no files")
			return fmt.Errorf("cannot create version entry with no files - at least one of OS image, OTA update, or recovery file must be provided")
		}

		manifest.Versions[version] = versionMetadata

		// Write back to bucket using GenerationMatch to prevent lost updates from
		// concurrent writers. Use DoesNotExist when creating a new object because
		// GenerationMatch:0 is the zero value and the GCS client rejects it as "empty conditions".
		logger.Info("Writing device manifest back to bucket")
		var deviceConds storage.Conditions
		if generation == 0 {
			deviceConds = storage.Conditions{DoesNotExist: true}
		} else {
			deviceConds = storage.Conditions{GenerationMatch: generation}
		}
		w := obj.If(deviceConds).NewWriter(ctx)
		w.CacheControl = manifestCacheControl

		// Marshal to JSON with indentation
		content, err := json.MarshalIndent(manifest, "", "  ")
		if err != nil {
			logger.WithError(err).Error("Failed to marshal device manifest")
			return fmt.Errorf("failed to marshal device manifest: %w", err)
		}

		// Write content
		if _, err := w.Write(content); err != nil {
			w.Close() // Close without checking error since write already failed
			logger.WithError(err).Error("Failed to write device manifest")
			return fmt.Errorf("failed to write device manifest: %w", err)
		}

		// Close to commit the write (MUST check error - this is when upload finalizes)
		if err := w.Close(); err != nil {
			var gErr *googleapi.Error
			if errors.As(err, &gErr) && gErr.Code == 412 && attempt < maxRetries {
				logger.WithField("attempt", attempt).Warn("Device manifest write lost race (412), retrying...")
				backoff := time.Duration(1<<uint(attempt))*100*time.Millisecond + time.Duration(rand.Intn(200))*time.Millisecond
				if backoff > 10*time.Second {
					backoff = 10 * time.Second
				}
				time.Sleep(backoff)
				continue
			}
			logger.WithError(err).Error("Failed to finalize device manifest write")
			return fmt.Errorf("failed to finalize device manifest write: %w", err)
		}

		logger.Info("Successfully wrote device manifest")
		return nil
	}
	return fmt.Errorf("failed to write device manifest after %d attempts: concurrent writers", maxRetries)
}

func updateMasterManifest(ctx context.Context, logger *logrus.Entry, bucket *storage.BucketHandle, deviceType, version string, isNightly bool, stability string, forceWrite bool) error {
	masterManifestPath := "manifests/master.json"
	logger = logger.WithField("manifest_path", masterManifestPath)
	logger.Info("Processing master manifest")

	obj := bucket.Object(masterManifestPath)

	const maxRetries = 10
	for attempt := 1; attempt <= maxRetries; attempt++ {
		// Read existing manifest or create new one
		var masterManifest MasterManifest
		var generation int64 // 0 means object doesn't exist yet
		r, err := obj.NewReader(ctx)
		if err == nil {
			logger.Info("Reading existing master manifest")

			// Read content with size limit to prevent DoS
			limitedReader := io.LimitReader(r, 10*1024*1024) // 10MB limit
			content, err := io.ReadAll(limitedReader)
			generation = r.Attrs.Generation
			r.Close()
			if err != nil {
				logger.WithError(err).Error("Failed to read existing master manifest")
				return fmt.Errorf("failed to read existing master manifest: %w", err)
			}

			// Unmarshal JSON
			if err := json.Unmarshal(content, &masterManifest); err != nil {
				logger.WithError(err).Error("Failed to decode existing master manifest")
				return fmt.Errorf("failed to decode existing master manifest: %w", err)
			}

			logger.WithField("device_count", len(masterManifest.Devices)).Info("Read existing master manifest")

			// Idempotent check: skip only for concurrent build jobs (forceWrite=false)
			// to break livelock. Force-write callers (the serialised publish job) must
			// always write so that last_updated is refreshed even when the version string
			// hasn't changed (e.g. repeated nightly builds with the same version tag).
			if !forceWrite {
				if existingInfo, ok := masterManifest.Devices[deviceType]; ok {
					expectedStability := stability
					if expectedStability == "" {
						expectedStability = "stable"
					}
					correctVersion := (isNightly && existingInfo.LatestNightly == version) ||
						(!isNightly && existingInfo.Latest == version)
					expectedPath := fmt.Sprintf("manifests/%s.json", deviceType)
					if correctVersion && existingInfo.ManifestPath == expectedPath && existingInfo.Stability == expectedStability {
						logger.Info("Master manifest already up-to-date, skipping write")
						return nil
					}
				}
			}
		} else {
			// Create new manifest if it doesn't exist
			logger.WithError(err).Info("Creating new master manifest as it doesn't exist")
			masterManifest = MasterManifest{
				Devices: make(map[string]DeviceLatestInfo),
			}
		}

		// Update master manifest
		logger.WithFields(logrus.Fields{
			"device_type": deviceType,
			"version":     version,
			"is_nightly":  isNightly,
			"stability":   stability,
		}).Info("Updating master manifest")

		masterManifest.LastUpdated = time.Now()

		// Get or create device info
		deviceInfo, exists := masterManifest.Devices[deviceType]
		if !exists {
			deviceInfo = DeviceLatestInfo{}
		}

		// Always set ManifestPath to ensure consistency
		deviceInfo.ManifestPath = fmt.Sprintf("manifests/%s.json", deviceType)

		// Set stability (defaults to "stable" if empty)
		if stability == "" {
			stability = "stable"
		}
		deviceInfo.Stability = stability

		// Update the appropriate latest version
		if isNightly {
			deviceInfo.LatestNightly = version
		} else {
			deviceInfo.Latest = version
		}

		masterManifest.Devices[deviceType] = deviceInfo

		logger.Info("Writing master manifest back to bucket")
		var w *storage.Writer
		if forceWrite {
			// Unconditional write: the caller guarantees exclusive access (e.g. publish
			// job with a concurrency group). Avoids livelock from any mystery concurrent
			// writer because we are the authoritative publisher.
			w = obj.NewWriter(ctx)
			w.CacheControl = manifestCacheControl
		} else {
			// Use GenerationMatch so concurrent build jobs don't clobber each other.
			var masterConds storage.Conditions
			if generation == 0 {
				masterConds = storage.Conditions{DoesNotExist: true}
			} else {
				masterConds = storage.Conditions{GenerationMatch: generation}
			}
			w = obj.If(masterConds).NewWriter(ctx)
			w.CacheControl = manifestCacheControl
		}

		// Marshal to JSON with indentation
		content, err := json.MarshalIndent(masterManifest, "", "  ")
		if err != nil {
			logger.WithError(err).Error("Failed to marshal master manifest")
			return fmt.Errorf("failed to marshal master manifest: %w", err)
		}

		// Write content
		if _, err := w.Write(content); err != nil {
			w.Close() // Close without checking error since write already failed
			logger.WithError(err).Error("Failed to write master manifest")
			return fmt.Errorf("failed to write master manifest: %w", err)
		}

		// Close to commit the write (MUST check error - this is when upload finalizes)
		if err := w.Close(); err != nil {
			var gErr *googleapi.Error
			if errors.As(err, &gErr) && gErr.Code == 412 && attempt < maxRetries {
				logger.WithField("attempt", attempt).Warn("Master manifest write lost race (412), retrying...")
				backoff := time.Duration(1<<uint(attempt))*100*time.Millisecond + time.Duration(rand.Intn(200))*time.Millisecond
				if backoff > 10*time.Second {
					backoff = 10 * time.Second
				}
				time.Sleep(backoff)
				continue
			}
			logger.WithError(err).Error("Failed to finalize master manifest write")
			return fmt.Errorf("failed to finalize master manifest write: %w", err)
		}

		logger.Info("Successfully wrote master manifest")
		return nil
	}
	return fmt.Errorf("failed to write master manifest after %d attempts: concurrent writers", maxRetries)
}

// createNewDevice creates a new device type in both manifests
func createNewDevice(ctx context.Context, bucket *storage.BucketHandle, deviceType string, stability string) error {
	logger := log.WithFields(logrus.Fields{
		"device_type": deviceType,
		"stability":   stability,
	})
	logger.Info("Creating new device type")

	// Create empty device manifest
	manifestPath := fmt.Sprintf("manifests/%s.json", deviceType)
	manifest := DeviceManifest{
		DeviceID: deviceType,
		Versions: make(map[string]VersionMetadata),
	}

	// Write device manifest
	obj := bucket.Object(manifestPath)
	w := obj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl

	content, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		logger.WithError(err).Error("Failed to marshal device manifest")
		return fmt.Errorf("failed to marshal device manifest: %w", err)
	}

	if _, err := w.Write(content); err != nil {
		w.Close() // Close without checking error since write already failed
		logger.WithError(err).Error("Failed to write device manifest")
		return fmt.Errorf("failed to write device manifest: %w", err)
	}

	// Close to commit the write (MUST check error - this is when upload finalizes)
	if err := w.Close(); err != nil {
		logger.WithError(err).Error("Failed to finalize device manifest write")
		return fmt.Errorf("failed to finalize device manifest write: %w", err)
	}

	logger.Info("Successfully created device manifest")

	// Update master manifest to include the new device
	masterManifestPath := "manifests/master.json"
	masterObj := bucket.Object(masterManifestPath)

	var masterManifest MasterManifest
	r, err := masterObj.NewReader(ctx)
	if err == nil {
		defer r.Close()
		content, err := io.ReadAll(r)
		if err != nil {
			logger.WithError(err).Error("Failed to read master manifest")
			return fmt.Errorf("failed to read master manifest: %w", err)
		}

		if err := json.Unmarshal(content, &masterManifest); err != nil {
			logger.WithError(err).Error("Failed to decode master manifest")
			return fmt.Errorf("failed to decode master manifest: %w", err)
		}
	} else {
		masterManifest = MasterManifest{
			Devices: make(map[string]DeviceLatestInfo),
		}
	}

	// Add the new device to master manifest
	masterManifest.LastUpdated = time.Now()

	// Set stability (defaults to "stable" if empty)
	if stability == "" {
		stability = "stable"
	}

	masterManifest.Devices[deviceType] = DeviceLatestInfo{
		Latest:       "",
		ManifestPath: manifestPath,
		Stability:    stability,
	}

	// Write master manifest
	w = masterObj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl

	content, err = json.MarshalIndent(masterManifest, "", "  ")
	if err != nil {
		logger.WithError(err).Error("Failed to marshal master manifest")
		return fmt.Errorf("failed to marshal master manifest: %w", err)
	}

	if _, err := w.Write(content); err != nil {
		w.Close() // Close without checking error since write already failed
		logger.WithError(err).Error("Failed to write master manifest")
		return fmt.Errorf("failed to write master manifest: %w", err)
	}

	// Close to commit the write (MUST check error - this is when upload finalizes)
	if err := w.Close(); err != nil {
		logger.WithError(err).Error("Failed to finalize master manifest write")
		return fmt.Errorf("failed to finalize master manifest write: %w", err)
	}

	logger.Info("Successfully updated master manifest")
	return nil
}

// promoteNightlyToStable promotes a nightly build to stable release by removing "nightly" from version name
func promoteNightlyToStable(ctx context.Context, bucket *storage.BucketHandle, deviceType, nightlyVersion string, notifyDiscord bool) {
	logger := log.WithFields(logrus.Fields{
		"device_type":     deviceType,
		"nightly_version": nightlyVersion,
		"operation":       "promote",
	})
	logger.Info("Promoting nightly build to stable")

	// Transform version name (remove "nightly-" prefix or "-nightly" suffix)
	stableVersion := nightlyVersion
	if strings.HasPrefix(stableVersion, "nightly-") {
		stableVersion = strings.TrimPrefix(stableVersion, "nightly-")
	} else if strings.HasSuffix(stableVersion, "-nightly") {
		stableVersion = strings.TrimSuffix(stableVersion, "-nightly")
	} else if stableVersion == "nightly" {
		logger.Fatal("Cannot promote version 'nightly' - must have additional version info (e.g., 'nightly-2025-12-20')")
	} else if !strings.Contains(strings.ToLower(stableVersion), "nightly") {
		logger.Fatal("Version does not contain 'nightly' - cannot determine stable version name")
	}

	// CI nightlies named nightly-YYYYMMDDTHHMMSS don't embed a semantic
	// version: stripping the prefix would "promote" to a bare timestamp.
	// Those builds are released by tagging the commit MAJOR.MINOR.PATCH
	// (promote.yml), which rebuilds and publishes the real version.
	if !regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`).MatchString(stableVersion) {
		logger.Fatalf("Derived stable version %q is not MAJOR.MINOR.PATCH - cannot promote %q in place. Use the 'Promote Nightly to Release' GitHub workflow instead.", stableVersion, nightlyVersion)
	}

	logger.WithField("stable_version", stableVersion).Info("Derived stable version name")

	// Read device manifest
	manifestPath := fmt.Sprintf("manifests/%s.json", deviceType)
	obj := bucket.Object(manifestPath)

	var manifest DeviceManifest
	r, err := obj.NewReader(ctx)
	if err != nil {
		logger.WithError(err).Fatal("Failed to read device manifest - does the device exist?")
	}
	defer r.Close()

	content, err := io.ReadAll(r)
	if err != nil {
		logger.WithError(err).Fatal("Failed to read manifest content")
	}

	if err := json.Unmarshal(content, &manifest); err != nil {
		logger.WithError(err).Fatal("Failed to parse device manifest")
	}

	// Validate source version exists and is nightly
	sourceVersionMeta, exists := manifest.Versions[nightlyVersion]
	if !exists {
		logger.Fatal("Source version does not exist in manifest")
	}

	if !sourceVersionMeta.IsNightly {
		logger.Fatal("Source version is not a nightly build - cannot promote")
	}

	// Validate target version doesn't already exist
	if _, exists := manifest.Versions[stableVersion]; exists {
		logger.WithField("stable_version", stableVersion).Fatal("Target stable version already exists")
	}

	// Get source file path and parse to create destination path
	sourcePath := sourceVersionMeta.Path
	parts := strings.Split(sourcePath, "/")
	if len(parts) < 4 {
		logger.WithField("path", sourcePath).Fatal("Invalid source file path format")
	}
	filename := parts[len(parts)-1]
	destinationPath := fmt.Sprintf("images/%s/%s/%s", deviceType, stableVersion, filename)

	logger.WithFields(logrus.Fields{
		"source_path":      sourcePath,
		"destination_path": destinationPath,
	}).Info("Copying file to stable path")

	// Copy GCS file to new stable path using server-side copy
	srcObj := bucket.Object(sourcePath)
	dstObj := bucket.Object(destinationPath)
	copier := dstObj.CopierFrom(srcObj)

	attrs, err := copier.Run(ctx)
	if err != nil {
		logger.WithError(err).Fatal("Failed to copy file to stable path")
	}

	logger.WithField("size_bytes", attrs.Size).Info("File copied successfully")

	// Copy OTA update file if it exists
	var otaDestPath string
	if sourceVersionMeta.OTAUpdatePath != "" {
		otaParts := strings.Split(sourceVersionMeta.OTAUpdatePath, "/")
		if len(otaParts) >= 4 {
			otaFilename := otaParts[len(otaParts)-1]
			otaDestPath = fmt.Sprintf("images/%s/%s/%s", deviceType, stableVersion, otaFilename)

			otaSrcObj := bucket.Object(sourceVersionMeta.OTAUpdatePath)
			otaDstObj := bucket.Object(otaDestPath)
			otaCopier := otaDstObj.CopierFrom(otaSrcObj)

			if _, err := otaCopier.Run(ctx); err != nil {
				logger.WithError(err).Warn("Failed to copy OTA update file, continuing without it")
				otaDestPath = ""
			} else {
				logger.Info("OTA update file copied successfully")
			}
		}
	}

	// Copy recovery file if it exists
	var recoveryDestPath string
	if sourceVersionMeta.RecoveryPath != "" {
		recoveryParts := strings.Split(sourceVersionMeta.RecoveryPath, "/")
		if len(recoveryParts) >= 4 {
			recoveryFilename := recoveryParts[len(recoveryParts)-1]
			recoveryDestPath = fmt.Sprintf("images/%s/%s/%s", deviceType, stableVersion, recoveryFilename)

			recoverySrcObj := bucket.Object(sourceVersionMeta.RecoveryPath)
			recoveryDstObj := bucket.Object(recoveryDestPath)
			recoveryCopier := recoveryDstObj.CopierFrom(recoverySrcObj)

			if _, err := recoveryCopier.Run(ctx); err != nil {
				logger.WithError(err).Warn("Failed to copy recovery file, continuing without it")
				recoveryDestPath = ""
			} else {
				logger.Info("Recovery file copied successfully")
			}
		}
	}

	// Copy NVME image if present
	var nvmeDestPath, nvmeChecksum string
	if sourceVersionMeta.NVMEPath != "" {
		nvmeParts := strings.Split(sourceVersionMeta.NVMEPath, "/")
		if len(nvmeParts) >= 4 {
			nvmeDestPath = fmt.Sprintf("images/%s/%s/%s", deviceType, stableVersion, nvmeParts[len(nvmeParts)-1])
			if _, err := bucket.Object(nvmeDestPath).CopierFrom(bucket.Object(sourceVersionMeta.NVMEPath)).Run(ctx); err != nil {
				logger.WithError(err).Warn("Failed to copy NVME image, continuing without it")
				nvmeDestPath = ""
			} else {
				nvmeChecksum = sourceVersionMeta.NVMEChecksum
				logger.Info("NVME image copied successfully")
			}
		}
	}

	// Copy SD card image if present
	var sdDestPath, sdChecksum string
	if sourceVersionMeta.SDCardPath != "" {
		sdParts := strings.Split(sourceVersionMeta.SDCardPath, "/")
		if len(sdParts) >= 4 {
			sdDestPath = fmt.Sprintf("images/%s/%s/%s", deviceType, stableVersion, sdParts[len(sdParts)-1])
			if _, err := bucket.Object(sdDestPath).CopierFrom(bucket.Object(sourceVersionMeta.SDCardPath)).Run(ctx); err != nil {
				logger.WithError(err).Warn("Failed to copy SD card image, continuing without it")
				sdDestPath = ""
			} else {
				sdChecksum = sourceVersionMeta.SDCardChecksum
				logger.Info("SD card image copied successfully")
			}
		}
	}

	// Copy block maps, preserving the per-storage layout from upload time. A
	// bmap describes one image, so each follows its image to the stable path.
	// Top-level BmapPath mirrors top-level Path (NVMe) for older CLIs. A pre-fix
	// nightly that only carries the legacy top-level BmapPath is still promoted.
	nvmeBmapDest := copyManifestArtifact(ctx, logger, bucket, sourceVersionMeta.NVMEBmapPath, deviceType, stableVersion, "NVMe block map")
	sdBmapDest := copyManifestArtifact(ctx, logger, bucket, sourceVersionMeta.SDCardBmapPath, deviceType, stableVersion, "SD card block map")
	var topBmapDest string
	switch {
	case nvmeBmapDest != "":
		topBmapDest = nvmeBmapDest
	case sdBmapDest != "":
		topBmapDest = sdBmapDest
	case sourceVersionMeta.BmapPath != "":
		topBmapDest = copyManifestArtifact(ctx, logger, bucket, sourceVersionMeta.BmapPath, deviceType, stableVersion, "block map")
	}

	// Copy seekable-zstd images, mirroring bmap promotion. Each zst follows
	// its image to the stable path and retains its checksum/size metadata.
	nvmeZstDest := copyManifestArtifact(ctx, logger, bucket, sourceVersionMeta.NVMEZstPath, deviceType, stableVersion, "NVMe seekable-zstd")
	sdZstDest := copyManifestArtifact(ctx, logger, bucket, sourceVersionMeta.SDCardZstPath, deviceType, stableVersion, "SD card seekable-zstd")
	var topZstDest string
	switch {
	case nvmeZstDest != "":
		topZstDest = nvmeZstDest
	case sdZstDest != "":
		topZstDest = sdZstDest
	case sourceVersionMeta.ZstPath != "":
		topZstDest = copyManifestArtifact(ctx, logger, bucket, sourceVersionMeta.ZstPath, deviceType, stableVersion, "seekable-zstd")
	}

	// Create new stable version entry with promotion metadata
	promotedAt := time.Now()
	sourceVersion := nightlyVersion
	stableVersionMeta := VersionMetadata{
		ReleaseDate:    sourceVersionMeta.ReleaseDate,
		Path:           destinationPath,
		Checksum:       sourceVersionMeta.Checksum,
		SizeBytes:      sourceVersionMeta.SizeBytes,
		Changelog:      sourceVersionMeta.Changelog,
		IsLatest:       true,
		IsNightly:      false,
		PromotedFrom:   &sourceVersion,
		PromotedAt:     &promotedAt,
		NVMEPath:       nvmeDestPath,
		NVMEChecksum:   nvmeChecksum,
		SDCardPath:     sdDestPath,
		SDCardChecksum: sdChecksum,
		NVMEBmapPath:   nvmeBmapDest,
		SDCardBmapPath: sdBmapDest,
		BmapPath:       topBmapDest,
		ZstPath:        topZstDest,
		ZstChecksum: func() string {
			if nvmeZstDest != "" {
				return sourceVersionMeta.NVMEZstChecksum
			}
			if sdZstDest != "" {
				return sourceVersionMeta.SDCardZstChecksum
			}
			return sourceVersionMeta.ZstChecksum
		}(),
		ZstSizeBytes: func() int64 {
			if nvmeZstDest != "" {
				return sourceVersionMeta.NVMEZstSizeBytes
			}
			if sdZstDest != "" {
				return sourceVersionMeta.SDCardZstSizeBytes
			}
			return sourceVersionMeta.ZstSizeBytes
		}(),
		NVMEZstPath: nvmeZstDest,
		NVMEZstChecksum: func() string {
			if nvmeZstDest != "" {
				return sourceVersionMeta.NVMEZstChecksum
			}
			return ""
		}(),
		NVMEZstSizeBytes: func() int64 {
			if nvmeZstDest != "" {
				return sourceVersionMeta.NVMEZstSizeBytes
			}
			return 0
		}(),
		SDCardZstPath: sdZstDest,
		SDCardZstChecksum: func() string {
			if sdZstDest != "" {
				return sourceVersionMeta.SDCardZstChecksum
			}
			return ""
		}(),
		SDCardZstSizeBytes: func() int64 {
			if sdZstDest != "" {
				return sourceVersionMeta.SDCardZstSizeBytes
			}
			return 0
		}(),
		OTAUpdatePath:      otaDestPath,
		OTAUpdateChecksum:  sourceVersionMeta.OTAUpdateChecksum,
		OTAUpdateSizeBytes: sourceVersionMeta.OTAUpdateSizeBytes,
		RecoveryPath:       recoveryDestPath,
		RecoveryChecksum:   sourceVersionMeta.RecoveryChecksum,
		RecoverySizeBytes:  sourceVersionMeta.RecoverySizeBytes,
	}

	// Clear OTA/recovery fields if copy failed
	if otaDestPath == "" {
		stableVersionMeta.OTAUpdateChecksum = ""
		stableVersionMeta.OTAUpdateSizeBytes = 0
	}
	if recoveryDestPath == "" {
		stableVersionMeta.RecoveryChecksum = ""
		stableVersionMeta.RecoverySizeBytes = 0
	}

	// Update IsLatest flags - clear all stable versions
	for k, v := range manifest.Versions {
		if !v.IsNightly {
			v.IsLatest = false
			manifest.Versions[k] = v
		}
	}

	// Add new stable version
	manifest.Versions[stableVersion] = stableVersionMeta

	// Write device manifest back
	logger.Info("Writing updated device manifest")
	w := obj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl

	manifestContent, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		logger.WithError(err).Fatal("Failed to marshal device manifest")
	}

	if _, err := w.Write(manifestContent); err != nil {
		w.Close()
		logger.WithError(err).Fatal("Failed to write device manifest")
	}

	if err := w.Close(); err != nil {
		logger.WithError(err).Fatal("Failed to finalize device manifest write")
	}

	logger.Info("Successfully updated device manifest")

	// Update master manifest
	if err := updateMasterManifestForPromotion(ctx, logger, bucket, deviceType, stableVersion); err != nil {
		logger.WithError(err).Fatal("Failed to update master manifest after promotion")
	}

	logger.WithField("stable_version", stableVersion).Info("Successfully promoted nightly to stable")

	if notifyDiscord {
		if err := sendDiscordNotification(discordReleaseWebhookURL, deviceType, stableVersion, false, stableVersionMeta.SizeBytes, stableVersionMeta.OTAUpdateSizeBytes, stableVersionMeta.RecoverySizeBytes); err != nil {
			logger.WithError(err).Warn("Failed to send Discord notification")
		}
	}
}

// updateMasterManifestForPromotion updates master manifest after promotion
func updateMasterManifestForPromotion(ctx context.Context, logger *logrus.Entry, bucket *storage.BucketHandle, deviceType, stableVersion string) error {
	masterManifestPath := "manifests/master.json"
	obj := bucket.Object(masterManifestPath)

	const maxRetries = 10
	for attempt := 1; attempt <= maxRetries; attempt++ {
		r, err := obj.NewReader(ctx)
		if err != nil {
			return fmt.Errorf("failed to read master manifest: %w", err)
		}
		content, err := io.ReadAll(r)
		generation := r.Attrs.Generation
		r.Close()
		if err != nil {
			return fmt.Errorf("failed to read master manifest content: %w", err)
		}

		var masterManifest MasterManifest
		if err := json.Unmarshal(content, &masterManifest); err != nil {
			return fmt.Errorf("failed to decode master manifest: %w", err)
		}

		deviceInfo, exists := masterManifest.Devices[deviceType]
		if !exists {
			return fmt.Errorf("device %q does not exist in master manifest", deviceType)
		}

		// Idempotency on retries: if a concurrent writer already set the stable
		// version, accept that as success rather than burning another attempt.
		if attempt > 1 && deviceInfo.Latest == stableVersion {
			logger.Info("Master manifest already reflects promoted stable version")
			return nil
		}

		deviceInfo.Latest = stableVersion
		masterManifest.Devices[deviceType] = deviceInfo
		masterManifest.LastUpdated = time.Now()

		manifestContent, err := json.MarshalIndent(masterManifest, "", "  ")
		if err != nil {
			return fmt.Errorf("failed to marshal master manifest: %w", err)
		}

		w := obj.If(storage.Conditions{GenerationMatch: generation}).NewWriter(ctx)
		w.CacheControl = manifestCacheControl
		if _, err := w.Write(manifestContent); err != nil {
			w.Close()
			return fmt.Errorf("failed to write master manifest: %w", err)
		}
		if err := w.Close(); err != nil {
			var gErr *googleapi.Error
			if errors.As(err, &gErr) && gErr.Code == 412 && attempt < maxRetries {
				backoff := time.Duration(1<<uint(attempt))*100*time.Millisecond + time.Duration(rand.Intn(200))*time.Millisecond
				if backoff > 10*time.Second {
					backoff = 10 * time.Second
				}
				logger.WithField("attempt", attempt).Warn("Master manifest write lost race (412), retrying...")
				time.Sleep(backoff)
				continue
			}
			return fmt.Errorf("failed to finalize master manifest write: %w", err)
		}

		logger.Info("Successfully updated master manifest")
		return nil
	}
	return fmt.Errorf("failed to update master manifest after %d attempts", maxRetries)
}

// swapImageFile replaces an existing version's image file while preserving metadata
func swapImageFile(ctx context.Context, bucket *storage.BucketHandle, deviceType, version, localFile, recoveryFile string, isNightly bool) {
	logger := log.WithFields(logrus.Fields{
		"device_type":   deviceType,
		"version":       version,
		"local_file":    localFile,
		"recovery_file": recoveryFile,
		"is_nightly":    isNightly,
		"operation":     "swap",
	})
	logger.Info("Starting image file swap")

	// Read device manifest to validate version exists
	manifestPath := fmt.Sprintf("manifests/%s.json", deviceType)
	obj := bucket.Object(manifestPath)

	var manifest DeviceManifest
	r, err := obj.NewReader(ctx)
	if err != nil {
		logger.WithError(err).Fatal("Failed to read device manifest - does the device exist?")
	}
	defer r.Close()

	content, err := io.ReadAll(r)
	if err != nil {
		logger.WithError(err).Fatal("Failed to read manifest content")
	}

	if err := json.Unmarshal(content, &manifest); err != nil {
		logger.WithError(err).Fatal("Failed to parse device manifest")
	}

	// Validate version exists
	existingVersion, exists := manifest.Versions[version]
	if !exists {
		logger.WithField("version", version).Fatal("Cannot swap - version does not exist. Use normal upload to create new version.")
	}

	// Verify IsNightly flag matches
	if existingVersion.IsNightly != isNightly {
		logger.WithFields(logrus.Fields{
			"existing_is_nightly":  existingVersion.IsNightly,
			"requested_is_nightly": isNightly,
		}).Fatal("Cannot swap - IsNightly flag mismatch. Version is " +
			map[bool]string{true: "nightly", false: "stable"}[existingVersion.IsNightly] +
			" but --nightly flag is " +
			map[bool]string{true: "set", false: "not set"}[isNightly])
	}

	// Upload new file
	newPath, err := uploadFile(ctx, bucket, localFile, deviceType, version)
	if err != nil {
		logger.WithError(err).Fatal("Failed to upload new file")
	}

	// Warn if filename changed
	oldFilename := filepath.Base(existingVersion.Path)
	newFilename := filepath.Base(localFile)
	if newFilename != oldFilename {
		logger.WithFields(logrus.Fields{
			"old_filename": oldFilename,
			"new_filename": newFilename,
		}).Warn("Filename changed during swap - old file will be orphaned")
	}

	// Get uploaded file size
	destObj := bucket.Object(newPath)
	attrs, err := destObj.Attrs(ctx)
	if err != nil {
		logger.WithError(err).Fatal("Failed to get uploaded file attributes")
	}

	// Calculate checksum of uploaded file
	logger.Info("Calculating checksum of uploaded file")
	checksum, err := calculateGCSChecksum(ctx, bucket, newPath)
	if err != nil {
		logger.WithError(err).Fatal("Failed to calculate checksum")
	}

	// Handle recovery file swap if provided
	var newRecoveryPath, newRecoveryChecksum string
	var newRecoverySize int64
	if recoveryFile != "" {
		recoveryPath, err := uploadFile(ctx, bucket, recoveryFile, deviceType, version)
		if err != nil {
			logger.WithError(err).Fatal("Failed to upload recovery file")
		}
		newRecoveryPath = recoveryPath

		recoveryObj := bucket.Object(recoveryPath)
		recoveryAttrs, err := recoveryObj.Attrs(ctx)
		if err != nil {
			logger.WithError(err).Fatal("Failed to get recovery file attributes")
		}
		newRecoverySize = recoveryAttrs.Size

		recoveryCS, err := calculateGCSChecksum(ctx, bucket, recoveryPath)
		if err != nil {
			logger.WithError(err).Fatal("Failed to calculate recovery checksum")
		}
		newRecoveryChecksum = recoveryCS
	}

	// Build updated metadata preserving historical fields
	swapCount := 1
	if existingVersion.SwapCount != nil {
		swapCount = *existingVersion.SwapCount + 1
	}
	swappedAt := time.Now()

	updatedVersion := VersionMetadata{
		// Preserved fields
		ReleaseDate:  existingVersion.ReleaseDate,
		Changelog:    existingVersion.Changelog,
		IsLatest:     existingVersion.IsLatest,
		IsNightly:    existingVersion.IsNightly,
		PromotedFrom: existingVersion.PromotedFrom,
		PromotedAt:   existingVersion.PromotedAt,

		// Updated fields
		Path:      newPath,
		SizeBytes: attrs.Size,
		Checksum:  checksum,
		SwappedAt: &swappedAt,
		SwapCount: &swapCount,

		// OTA preserved from existing
		OTAUpdatePath:      existingVersion.OTAUpdatePath,
		OTAUpdateChecksum:  existingVersion.OTAUpdateChecksum,
		OTAUpdateSizeBytes: existingVersion.OTAUpdateSizeBytes,
	}

	// Recovery: use new if provided, otherwise preserve existing
	if recoveryFile != "" {
		updatedVersion.RecoveryPath = newRecoveryPath
		updatedVersion.RecoveryChecksum = newRecoveryChecksum
		updatedVersion.RecoverySizeBytes = newRecoverySize
	} else {
		updatedVersion.RecoveryPath = existingVersion.RecoveryPath
		updatedVersion.RecoveryChecksum = existingVersion.RecoveryChecksum
		updatedVersion.RecoverySizeBytes = existingVersion.RecoverySizeBytes
	}

	// Write updated manifest
	manifest.Versions[version] = updatedVersion

	w := obj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl

	manifestContent, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		logger.WithError(err).Fatal("Failed to marshal device manifest")
	}

	if _, err := w.Write(manifestContent); err != nil {
		w.Close()
		logger.WithError(err).Fatal("Failed to write device manifest")
	}

	if err := w.Close(); err != nil {
		logger.WithError(err).Fatal("Failed to finalize device manifest write")
	}

	// Update master manifest timestamp only
	updateMasterManifestTimestamp(ctx, logger, bucket)

	logger.WithFields(logrus.Fields{
		"version":      version,
		"new_path":     newPath,
		"new_checksum": checksum,
		"swap_count":   swapCount,
	}).Info("Successfully swapped image file")
}

// calculateGCSChecksum calculates SHA256 checksum of a file in GCS
func calculateGCSChecksum(ctx context.Context, bucket *storage.BucketHandle, filePath string) (string, error) {
	obj := bucket.Object(filePath)
	r, err := obj.NewReader(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to read file for checksum: %w", err)
	}
	defer r.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, r); err != nil {
		return "", fmt.Errorf("failed to calculate checksum: %w", err)
	}

	return fmt.Sprintf("%x", hash.Sum(nil)), nil
}

// updateMasterManifestTimestamp updates only the timestamp in master manifest
func updateMasterManifestTimestamp(ctx context.Context, logger *logrus.Entry, bucket *storage.BucketHandle) {
	masterManifestPath := "manifests/master.json"
	obj := bucket.Object(masterManifestPath)

	var masterManifest MasterManifest
	r, err := obj.NewReader(ctx)
	if err != nil {
		logger.WithError(err).Fatal("Failed to read master manifest")
	}
	defer r.Close()

	content, err := io.ReadAll(r)
	if err != nil {
		logger.WithError(err).Fatal("Failed to read master manifest content")
	}

	if err := json.Unmarshal(content, &masterManifest); err != nil {
		logger.WithError(err).Fatal("Failed to decode master manifest")
	}

	masterManifest.LastUpdated = time.Now()

	w := obj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl

	manifestContent, err := json.MarshalIndent(masterManifest, "", "  ")
	if err != nil {
		logger.WithError(err).Fatal("Failed to marshal master manifest")
	}

	if _, err := w.Write(manifestContent); err != nil {
		w.Close()
		logger.WithError(err).Fatal("Failed to write master manifest")
	}

	if err := w.Close(); err != nil {
		logger.WithError(err).Fatal("Failed to finalize master manifest write")
	}

	logger.Info("Updated master manifest timestamp")
}

// uploadFirmwareFile uploads a firmware .bin file to GCS under firmware/<chip>/<version>/
func uploadFirmwareFile(ctx context.Context, bucket *storage.BucketHandle, localPath, chip, version string) (string, error) {
	filename := filepath.Base(localPath)
	destinationPath := fmt.Sprintf("firmware/%s/%s/%s", chip, version, filename)

	log.WithFields(logrus.Fields{
		"local_path":  localPath,
		"destination": destinationPath,
	}).Info("Uploading firmware file")

	// Open the local file
	file, err := os.Open(localPath)
	if err != nil {
		log.WithError(err).Error("Failed to open local firmware file")
		return "", fmt.Errorf("failed to open file %s: %w", localPath, err)
	}
	defer file.Close()

	// Create the destination object
	obj := bucket.Object(destinationPath)
	w := obj.NewWriter(ctx)
	w.ContentType = "application/octet-stream"

	// Stream the content
	if _, err := io.Copy(w, file); err != nil {
		w.Close() // Close without checking error since write already failed
		log.WithError(err).Error("Failed to write firmware to GCS")
		return "", fmt.Errorf("failed to write to GCS: %w", err)
	}

	// Close to commit the write (MUST check error - this is when upload finalizes)
	if err := w.Close(); err != nil {
		log.WithError(err).Error("Failed to close GCS writer for firmware")
		return "", fmt.Errorf("failed to finalize firmware upload: %w", err)
	}

	log.WithField("path", destinationPath).Info("Firmware file uploaded successfully")
	return destinationPath, nil
}

// updateFirmwareManifests orchestrates parallel chip manifest + master manifest update, verification, and Discord notification
func updateFirmwareManifests(ctx context.Context, bucket *storage.BucketHandle, chip, version, filePath string, fileSize int64, fileChecksum string, isNightly bool, notifyDiscord bool) {
	logger := log.WithFields(logrus.Fields{
		"chip":           chip,
		"version":        version,
		"file_path":      filePath,
		"is_nightly":     isNightly,
		"notify_discord": notifyDiscord,
	})
	logger.Info("Updating firmware manifests in parallel")

	// Update chip and master manifests in parallel
	var wg sync.WaitGroup
	wg.Add(2)

	chipFields := logrus.Fields{
		"chip":          chip,
		"version":       version,
		"file_path":     filePath,
		"is_nightly":    isNightly,
		"manifest_type": "chip",
	}
	masterFields := logrus.Fields{
		"chip":          chip,
		"version":       version,
		"is_nightly":    isNightly,
		"manifest_type": "master",
	}

	chipErrChan := make(chan error, 1)
	masterErrChan := make(chan error, 1)

	go func() {
		defer wg.Done()
		chipLogger := log.WithFields(chipFields)
		chipErrChan <- updateFirmwareChipManifest(ctx, chipLogger, bucket, chip, version, filePath, fileSize, fileChecksum, isNightly)
	}()

	go func() {
		defer wg.Done()
		masterLogger := log.WithFields(masterFields)
		masterErrChan <- updateMasterManifestFirmware(ctx, masterLogger, bucket, chip, version, isNightly)
	}()

	wg.Wait()
	close(chipErrChan)
	close(masterErrChan)

	// Check for errors
	if chipErr := <-chipErrChan; chipErr != nil {
		logger.WithError(chipErr).Fatal("Failed to update firmware chip manifest")
	}
	if masterErr := <-masterErrChan; masterErr != nil {
		logger.WithError(masterErr).Fatal("Failed to update master manifest for firmware")
	}

	logger.Info("Firmware manifests updated successfully")

	// Small delay to ensure manifest write is fully propagated
	time.Sleep(2 * time.Second)

	// Verify the upload before sending notifications
	logger.Info("Verifying firmware upload integrity...")
	if err := verifyFirmwareUpload(ctx, logger, bucket, chip, version, filePath, fileChecksum); err != nil {
		logger.WithError(err).Warn("Firmware upload verification failed - retrying once...")

		time.Sleep(2 * time.Second)
		if err := verifyFirmwareUpload(ctx, logger, bucket, chip, version, filePath, fileChecksum); err != nil {
			logger.WithError(err).Fatal("Firmware upload verification failed after retry")
		}
	}
	logger.Info("Firmware upload verification passed")

	// Send Discord notification if requested
	if notifyDiscord {
		logger.Info("Sending firmware Discord notification")
		if err := sendFirmwareDiscordNotification(chip, version, isNightly, fileSize); err != nil {
			logger.WithError(err).Warn("Failed to send firmware Discord notification (upload was still successful)")
		}
	}
}

// updateFirmwareChipManifest reads/creates manifests/<chip>.json as FirmwareManifest, updates version, writes back
func updateFirmwareChipManifest(ctx context.Context, logger *logrus.Entry, bucket *storage.BucketHandle, chip, version, filePath string, fileSize int64, fileChecksum string, isNightly bool) error {
	manifestPath := fmt.Sprintf("manifests/%s.json", chip)
	logger = logger.WithField("manifest_path", manifestPath)
	logger.Info("Processing firmware chip manifest")

	obj := bucket.Object(manifestPath)

	// Read existing manifest or create new one
	var manifest FirmwareManifest
	r, err := obj.NewReader(ctx)
	if err == nil {
		defer r.Close()
		logger.Info("Reading existing firmware chip manifest")

		// Read content with size limit to prevent DoS
		limitedReader := io.LimitReader(r, 10*1024*1024) // 10MB limit
		content, err := io.ReadAll(limitedReader)
		if err != nil {
			logger.WithError(err).Error("Failed to read existing firmware chip manifest")
			return fmt.Errorf("failed to read existing firmware chip manifest: %w", err)
		}

		if err := json.Unmarshal(content, &manifest); err != nil {
			logger.WithError(err).Error("Failed to decode existing firmware chip manifest")
			return fmt.Errorf("failed to decode existing firmware chip manifest: %w", err)
		}

		logger.WithField("version_count", len(manifest.Versions)).Info("Read existing firmware manifest")
	} else {
		logger.WithError(err).Info("Creating new firmware chip manifest as it doesn't exist")
		manifest = FirmwareManifest{
			ChipID:   chip,
			Versions: make(map[string]FirmwareVersionMetadata),
		}
	}

	// Update IsLatest flags based on nightly/stable
	if isNightly {
		for k, v := range manifest.Versions {
			if v.IsNightly {
				v.IsLatest = false
				manifest.Versions[k] = v
			}
		}
		logger.WithField("version", version).Info("Setting firmware version as latest nightly")
	} else {
		for k, v := range manifest.Versions {
			if !v.IsNightly {
				v.IsLatest = false
				manifest.Versions[k] = v
			}
		}
		logger.WithField("version", version).Info("Setting firmware version as latest stable")
	}

	// Add or update this version
	versionMetadata := FirmwareVersionMetadata{
		ReleaseDate: time.Now(),
		Path:        filePath,
		Checksum:    fileChecksum,
		SizeBytes:   fileSize,
		IsLatest:    true,
		IsNightly:   isNightly,
	}

	manifest.Versions[version] = versionMetadata

	// Write back to bucket
	logger.Info("Writing firmware chip manifest back to bucket")
	w := obj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl

	content, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		logger.WithError(err).Error("Failed to marshal firmware chip manifest")
		return fmt.Errorf("failed to marshal firmware chip manifest: %w", err)
	}

	if _, err := w.Write(content); err != nil {
		w.Close() // Close without checking error since write already failed
		logger.WithError(err).Error("Failed to write firmware chip manifest")
		return fmt.Errorf("failed to write firmware chip manifest: %w", err)
	}

	if err := w.Close(); err != nil {
		logger.WithError(err).Error("Failed to finalize firmware chip manifest write")
		return fmt.Errorf("failed to finalize firmware chip manifest write: %w", err)
	}

	logger.Info("Successfully wrote firmware chip manifest")
	return nil
}

// updateMasterManifestFirmware reads master.json, ensures Firmware map exists, updates chip entry
func updateMasterManifestFirmware(ctx context.Context, logger *logrus.Entry, bucket *storage.BucketHandle, chip, version string, isNightly bool) error {
	masterManifestPath := "manifests/master.json"
	logger = logger.WithField("manifest_path", masterManifestPath)
	logger.Info("Processing master manifest for firmware")

	obj := bucket.Object(masterManifestPath)

	// Read existing manifest or create new one
	var masterManifest MasterManifest
	r, err := obj.NewReader(ctx)
	if err == nil {
		defer r.Close()
		logger.Info("Reading existing master manifest")

		limitedReader := io.LimitReader(r, 10*1024*1024) // 10MB limit
		content, err := io.ReadAll(limitedReader)
		if err != nil {
			logger.WithError(err).Error("Failed to read existing master manifest")
			return fmt.Errorf("failed to read existing master manifest: %w", err)
		}

		if err := json.Unmarshal(content, &masterManifest); err != nil {
			logger.WithError(err).Error("Failed to decode existing master manifest")
			return fmt.Errorf("failed to decode existing master manifest: %w", err)
		}

		logger.WithField("device_count", len(masterManifest.Devices)).Info("Read existing master manifest")
	} else {
		logger.WithError(err).Info("Creating new master manifest as it doesn't exist")
		masterManifest = MasterManifest{
			Devices: make(map[string]DeviceLatestInfo),
		}
	}

	// Ensure Firmware map exists
	if masterManifest.Firmware == nil {
		masterManifest.Firmware = make(map[string]DeviceLatestInfo)
	}

	logger.WithFields(logrus.Fields{
		"chip":       chip,
		"version":    version,
		"is_nightly": isNightly,
	}).Info("Updating master manifest firmware entry")

	masterManifest.LastUpdated = time.Now()

	// Get or create chip info
	chipInfo, exists := masterManifest.Firmware[chip]
	if !exists {
		chipInfo = DeviceLatestInfo{}
	}

	chipInfo.ManifestPath = fmt.Sprintf("manifests/%s.json", chip)

	if isNightly {
		chipInfo.LatestNightly = version
	} else {
		chipInfo.Latest = version
	}

	masterManifest.Firmware[chip] = chipInfo

	// Write back to bucket
	logger.Info("Writing master manifest back to bucket")
	w := obj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl

	content, err := json.MarshalIndent(masterManifest, "", "  ")
	if err != nil {
		logger.WithError(err).Error("Failed to marshal master manifest")
		return fmt.Errorf("failed to marshal master manifest: %w", err)
	}

	if _, err := w.Write(content); err != nil {
		w.Close() // Close without checking error since write already failed
		logger.WithError(err).Error("Failed to write master manifest")
		return fmt.Errorf("failed to write master manifest: %w", err)
	}

	if err := w.Close(); err != nil {
		logger.WithError(err).Error("Failed to finalize master manifest write")
		return fmt.Errorf("failed to finalize master manifest write: %w", err)
	}

	logger.Info("Successfully wrote master manifest for firmware")
	return nil
}

// verifyFirmwareUpload reads back chip manifest, verifies version exists with correct path/checksum
func verifyFirmwareUpload(ctx context.Context, logger *logrus.Entry, bucket *storage.BucketHandle, chip, version, expectedPath, expectedChecksum string) error {
	logger.Info("Reading back firmware chip manifest for verification")

	manifestPath := fmt.Sprintf("manifests/%s.json", chip)
	obj := bucket.Object(manifestPath)
	r, err := obj.NewReader(ctx)
	if err != nil {
		return fmt.Errorf("failed to read back firmware manifest: %w", err)
	}
	defer r.Close()

	limitedReader := io.LimitReader(r, 10*1024*1024) // 10MB limit
	content, err := io.ReadAll(limitedReader)
	if err != nil {
		return fmt.Errorf("failed to read firmware manifest content: %w", err)
	}

	var manifest FirmwareManifest
	if err := json.Unmarshal(content, &manifest); err != nil {
		return fmt.Errorf("failed to parse firmware manifest JSON: %w", err)
	}

	logger.WithFields(logrus.Fields{
		"manifest_chip_id": manifest.ChipID,
		"version_count":    len(manifest.Versions),
		"looking_for":      version,
	}).Debug("Firmware manifest loaded for verification")

	// Verify version exists in manifest
	versionData, exists := manifest.Versions[version]
	if !exists {
		return fmt.Errorf("firmware version %s not found in manifest after update", version)
	}

	// Verify path
	if expectedPath != "" && versionData.Path != expectedPath {
		return fmt.Errorf("firmware path mismatch: manifest has %q, expected %q", versionData.Path, expectedPath)
	}

	// Verify file exists at that path
	fileObj := bucket.Object(versionData.Path)
	attrs, err := fileObj.Attrs(ctx)
	if err != nil {
		return fmt.Errorf("firmware file not found at path %s: %w", versionData.Path, err)
	}
	logger.WithField("size", attrs.Size).Info("Firmware file verified")

	// Verify checksum if provided
	if expectedChecksum != "" && versionData.Checksum != expectedChecksum {
		return fmt.Errorf("firmware checksum mismatch: manifest has %q, expected %q", versionData.Checksum, expectedChecksum)
	}

	logger.WithFields(logrus.Fields{
		"chip":    chip,
		"version": version,
		"path":    versionData.Path,
	}).Info("Firmware upload verified successfully")

	return nil
}

// sendFirmwareDiscordNotification sends a Discord embed with firmware publication details
func sendFirmwareDiscordNotification(chip, version string, isNightly bool, fileSize int64) error {
	if discordWebhookURL == "" {
		return fmt.Errorf("DISCORD_WEBHOOK_URL environment variable is not set")
	}
	buildType := "Stable"
	color := colorStable
	if isNightly {
		buildType = "Nightly"
		color = colorNightly
	}

	// Format firmware size in KB since .bin files are small
	sizeStr := fmt.Sprintf("%.2f KB", float64(fileSize)/1024)

	fields := []DiscordEmbedField{
		{
			Name:   "Chip",
			Value:  chip,
			Inline: true,
		},
		{
			Name:   "Version",
			Value:  version,
			Inline: true,
		},
		{
			Name:   "Build Type",
			Value:  buildType,
			Inline: true,
		},
		{
			Name:   "Firmware Size",
			Value:  sizeStr,
			Inline: true,
		},
		{
			Name:   "Status",
			Value:  "Successfully Published",
			Inline: false,
		},
	}

	embed := DiscordEmbed{
		Title:       "New Firmware Published",
		Description: fmt.Sprintf("Firmware update for **%s** version **%s** has been published", chip, version),
		Color:       color,
		Fields:      fields,
		Timestamp:   time.Now().Format(time.RFC3339),
	}

	payload := DiscordWebhookPayload{
		Embeds: []DiscordEmbed{embed},
	}

	jsonData, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("failed to marshal Discord payload: %w", err)
	}

	client := &http.Client{
		Timeout: 30 * time.Second,
	}

	resp, err := client.Post(discordWebhookURL, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return fmt.Errorf("failed to send firmware Discord notification: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		limitedBody := io.LimitReader(resp.Body, 1024*1024) // 1MB limit
		body, readErr := io.ReadAll(limitedBody)
		if readErr != nil {
			return fmt.Errorf("Discord API returned status %d (could not read body: %w)", resp.StatusCode, readErr)
		}
		return fmt.Errorf("Discord API returned status %d: %s", resp.StatusCode, string(body))
	}

	log.Info("Firmware Discord notification sent successfully")
	return nil
}

// createNewFirmwareChip creates a new firmware chip type in both manifests
func createNewFirmwareChip(ctx context.Context, bucket *storage.BucketHandle, chip string) error {
	logger := log.WithFields(logrus.Fields{
		"chip": chip,
	})
	logger.Info("Creating new firmware chip type")

	// Create empty firmware manifest
	manifestPath := fmt.Sprintf("manifests/%s.json", chip)
	manifest := FirmwareManifest{
		ChipID:   chip,
		Versions: make(map[string]FirmwareVersionMetadata),
	}

	// Write chip manifest
	obj := bucket.Object(manifestPath)
	w := obj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl

	content, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		logger.WithError(err).Error("Failed to marshal firmware chip manifest")
		return fmt.Errorf("failed to marshal firmware chip manifest: %w", err)
	}

	if _, err := w.Write(content); err != nil {
		w.Close() // Close without checking error since write already failed
		logger.WithError(err).Error("Failed to write firmware chip manifest")
		return fmt.Errorf("failed to write firmware chip manifest: %w", err)
	}

	if err := w.Close(); err != nil {
		logger.WithError(err).Error("Failed to finalize firmware chip manifest write")
		return fmt.Errorf("failed to finalize firmware chip manifest write: %w", err)
	}

	logger.Info("Successfully created firmware chip manifest")

	// Update master manifest to include the new chip in firmware section
	masterManifestPath := "manifests/master.json"
	masterObj := bucket.Object(masterManifestPath)

	var masterManifest MasterManifest
	r, err := masterObj.NewReader(ctx)
	if err == nil {
		defer r.Close()
		// Limit read size to prevent DoS
		limitedReader := io.LimitReader(r, 10*1024*1024) // 10MB limit
		content, err := io.ReadAll(limitedReader)
		if err != nil {
			logger.WithError(err).Error("Failed to read master manifest")
			return fmt.Errorf("failed to read master manifest: %w", err)
		}

		if err := json.Unmarshal(content, &masterManifest); err != nil {
			logger.WithError(err).Error("Failed to decode master manifest")
			return fmt.Errorf("failed to decode master manifest: %w", err)
		}
	} else {
		masterManifest = MasterManifest{
			Devices: make(map[string]DeviceLatestInfo),
		}
	}

	// Ensure Firmware map exists
	if masterManifest.Firmware == nil {
		masterManifest.Firmware = make(map[string]DeviceLatestInfo)
	}

	// Add the new chip to master manifest firmware section
	masterManifest.LastUpdated = time.Now()
	masterManifest.Firmware[chip] = DeviceLatestInfo{
		Latest:       "",
		ManifestPath: manifestPath,
	}

	// Write master manifest
	w = masterObj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl

	content, err = json.MarshalIndent(masterManifest, "", "  ")
	if err != nil {
		logger.WithError(err).Error("Failed to marshal master manifest")
		return fmt.Errorf("failed to marshal master manifest: %w", err)
	}

	if _, err := w.Write(content); err != nil {
		w.Close() // Close without checking error since write already failed
		logger.WithError(err).Error("Failed to write master manifest")
		return fmt.Errorf("failed to write master manifest: %w", err)
	}

	if err := w.Close(); err != nil {
		logger.WithError(err).Error("Failed to finalize master manifest write")
		return fmt.Errorf("failed to finalize master manifest write: %w", err)
	}

	logger.Info("Successfully updated master manifest with new firmware chip")
	return nil
}

// deleteObjectsByPrefix deletes all objects in the bucket with the given prefix
func deleteObjectsByPrefix(ctx context.Context, bucket *storage.BucketHandle, prefix string) (int, error) {
	it := bucket.Objects(ctx, &storage.Query{Prefix: prefix})
	deleted := 0

	for {
		attrs, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			return deleted, fmt.Errorf("listing objects with prefix %q: %w", prefix, err)
		}

		if err := bucket.Object(attrs.Name).Delete(ctx); err != nil {
			return deleted, fmt.Errorf("deleting object %q: %w", attrs.Name, err)
		}
		deleted++
		log.WithField("object", attrs.Name).Debug("Deleted object")
	}

	return deleted, nil
}

// removeDeviceType removes a device type from the manifests and optionally deletes its files
func removeDeviceType(ctx context.Context, bucket *storage.BucketHandle, deviceType string, deleteFiles bool) error {
	logger := log.WithFields(logrus.Fields{
		"device_type":  deviceType,
		"delete_files": deleteFiles,
	})
	logger.Info("Removing device type")

	// Read the master manifest
	masterManifestPath := "manifests/master.json"
	masterObj := bucket.Object(masterManifestPath)

	var masterManifest MasterManifest
	r, err := masterObj.NewReader(ctx)
	if err != nil {
		logger.WithError(err).Error("Failed to read master manifest")
		return fmt.Errorf("failed to read master manifest: %w", err)
	}
	limitedReader := io.LimitReader(r, 10*1024*1024)
	content, err := io.ReadAll(limitedReader)
	r.Close()
	if err != nil {
		logger.WithError(err).Error("Failed to read master manifest content")
		return fmt.Errorf("failed to read master manifest: %w", err)
	}

	if err := json.Unmarshal(content, &masterManifest); err != nil {
		logger.WithError(err).Error("Failed to decode master manifest")
		return fmt.Errorf("failed to decode master manifest: %w", err)
	}

	// Check that the device exists
	if _, exists := masterManifest.Devices[deviceType]; !exists {
		logger.Error("Device type not found in master manifest")
		return fmt.Errorf("device type %q not found in master manifest", deviceType)
	}

	// Delete uploaded files if requested
	if deleteFiles {
		prefix := fmt.Sprintf("images/%s/", deviceType)
		logger.WithField("prefix", prefix).Info("Deleting uploaded images")
		deleted, err := deleteObjectsByPrefix(ctx, bucket, prefix)
		if err != nil {
			logger.WithError(err).Error("Failed to delete images")
			return fmt.Errorf("failed to delete images: %w", err)
		}
		logger.WithField("deleted_count", deleted).Info("Deleted image files")
	}

	// Delete the device manifest
	manifestPath := fmt.Sprintf("manifests/%s.json", deviceType)
	logger.WithField("manifest_path", manifestPath).Info("Deleting device manifest")
	if err := bucket.Object(manifestPath).Delete(ctx); err != nil {
		logger.WithError(err).Warn("Failed to delete device manifest (may not exist)")
	} else {
		logger.Info("Deleted device manifest")
	}

	// Remove from master manifest and write it back
	delete(masterManifest.Devices, deviceType)
	masterManifest.LastUpdated = time.Now()

	w := masterObj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl
	updatedContent, err := json.MarshalIndent(masterManifest, "", "  ")
	if err != nil {
		logger.WithError(err).Error("Failed to marshal master manifest")
		return fmt.Errorf("failed to marshal master manifest: %w", err)
	}

	if _, err := w.Write(updatedContent); err != nil {
		w.Close()
		logger.WithError(err).Error("Failed to write master manifest")
		return fmt.Errorf("failed to write master manifest: %w", err)
	}

	if err := w.Close(); err != nil {
		logger.WithError(err).Error("Failed to finalize master manifest write")
		return fmt.Errorf("failed to finalize master manifest write: %w", err)
	}

	logger.Info("Successfully removed device type")
	return nil
}

// copyObject copies a GCS object from src to dst within the same bucket
func copyObject(ctx context.Context, bucket *storage.BucketHandle, src, dst string) error {
	srcObj := bucket.Object(src)
	dstObj := bucket.Object(dst)
	if _, err := dstObj.CopierFrom(srcObj).Run(ctx); err != nil {
		return fmt.Errorf("copying %q to %q: %w", src, dst, err)
	}
	return nil
}

// renameDeviceType moves all files and manifest data from one device type to another
func renameDeviceType(ctx context.Context, bucket *storage.BucketHandle, oldDevice, newDevice string) error {
	logger := log.WithFields(logrus.Fields{
		"old_device": oldDevice,
		"new_device": newDevice,
	})
	logger.Info("Renaming device type")

	// Read the master manifest
	masterManifestPath := "manifests/master.json"
	masterObj := bucket.Object(masterManifestPath)

	var masterManifest MasterManifest
	r, err := masterObj.NewReader(ctx)
	if err != nil {
		return fmt.Errorf("failed to read master manifest: %w", err)
	}
	limitedReader := io.LimitReader(r, 10*1024*1024)
	content, err := io.ReadAll(limitedReader)
	r.Close()
	if err != nil {
		return fmt.Errorf("failed to read master manifest: %w", err)
	}

	if err := json.Unmarshal(content, &masterManifest); err != nil {
		return fmt.Errorf("failed to decode master manifest: %w", err)
	}

	// Verify source device exists
	oldInfo, exists := masterManifest.Devices[oldDevice]
	if !exists {
		return fmt.Errorf("source device %q not found in master manifest", oldDevice)
	}

	// Read the source device manifest
	oldManifestPath := fmt.Sprintf("manifests/%s.json", oldDevice)
	oldManifestObj := bucket.Object(oldManifestPath)

	var deviceManifest DeviceManifest
	mr, err := oldManifestObj.NewReader(ctx)
	if err != nil {
		return fmt.Errorf("failed to read source device manifest: %w", err)
	}
	manifestContent, err := io.ReadAll(io.LimitReader(mr, 10*1024*1024))
	mr.Close()
	if err != nil {
		return fmt.Errorf("failed to read source device manifest: %w", err)
	}
	if err := json.Unmarshal(manifestContent, &deviceManifest); err != nil {
		return fmt.Errorf("failed to decode source device manifest: %w", err)
	}

	// If target device already exists, read its manifest to merge into
	var targetManifest DeviceManifest
	newManifestPath := fmt.Sprintf("manifests/%s.json", newDevice)
	newManifestObj := bucket.Object(newManifestPath)

	tmr, err := newManifestObj.NewReader(ctx)
	if err == nil {
		tmContent, err := io.ReadAll(io.LimitReader(tmr, 10*1024*1024))
		tmr.Close()
		if err != nil {
			return fmt.Errorf("failed to read target device manifest: %w", err)
		}
		if err := json.Unmarshal(tmContent, &targetManifest); err != nil {
			return fmt.Errorf("failed to decode target device manifest: %w", err)
		}
		logger.WithField("existing_versions", len(targetManifest.Versions)).Info("Target device already exists, merging versions")
	} else {
		targetManifest = DeviceManifest{
			DeviceID: newDevice,
			Versions: make(map[string]VersionMetadata),
		}
	}

	// Copy all image files from old device to new device
	oldPrefix := fmt.Sprintf("images/%s/", oldDevice)
	newPrefix := fmt.Sprintf("images/%s/", newDevice)
	logger.WithFields(logrus.Fields{
		"old_prefix": oldPrefix,
		"new_prefix": newPrefix,
	}).Info("Copying image files")

	it := bucket.Objects(ctx, &storage.Query{Prefix: oldPrefix})
	var copied int
	for {
		attrs, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			return fmt.Errorf("listing objects: %w", err)
		}

		newPath := newPrefix + strings.TrimPrefix(attrs.Name, oldPrefix)
		if err := copyObject(ctx, bucket, attrs.Name, newPath); err != nil {
			return fmt.Errorf("copying file: %w", err)
		}
		copied++
		log.WithFields(logrus.Fields{
			"from": attrs.Name,
			"to":   newPath,
		}).Debug("Copied file")
	}
	logger.WithField("copied_count", copied).Info("Copied image files")

	// Merge versions from source into target, updating paths
	for version, meta := range deviceManifest.Versions {
		// Update the path to point to the new device location
		meta.Path = strings.Replace(meta.Path, oldPrefix, newPrefix, 1)
		if meta.OTAUpdatePath != "" {
			meta.OTAUpdatePath = strings.Replace(meta.OTAUpdatePath, oldPrefix, newPrefix, 1)
		}
		if meta.RecoveryPath != "" {
			meta.RecoveryPath = strings.Replace(meta.RecoveryPath, oldPrefix, newPrefix, 1)
		}
		targetManifest.Versions[version] = meta
	}
	targetManifest.DeviceID = newDevice

	// Write the new device manifest
	w := newManifestObj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl
	newContent, err := json.MarshalIndent(targetManifest, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal target device manifest: %w", err)
	}
	if _, err := w.Write(newContent); err != nil {
		w.Close()
		return fmt.Errorf("failed to write target device manifest: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("failed to finalize target device manifest: %w", err)
	}
	logger.Info("Wrote target device manifest")

	// Delete old image files
	deleted, err := deleteObjectsByPrefix(ctx, bucket, oldPrefix)
	if err != nil {
		return fmt.Errorf("failed to delete old image files: %w", err)
	}
	logger.WithField("deleted_count", deleted).Info("Deleted old image files")

	// Delete old device manifest
	if err := oldManifestObj.Delete(ctx); err != nil {
		logger.WithError(err).Warn("Failed to delete old device manifest")
	} else {
		logger.Info("Deleted old device manifest")
	}

	// Update master manifest: remove old, add/update new
	delete(masterManifest.Devices, oldDevice)
	oldInfo.ManifestPath = newManifestPath

	// Preserve existing target info if it was already there
	if existingInfo, exists := masterManifest.Devices[newDevice]; exists {
		// Keep the target's stability, update versions from source if they're newer
		if oldInfo.Latest != "" {
			existingInfo.Latest = oldInfo.Latest
		}
		if oldInfo.LatestNightly != "" {
			existingInfo.LatestNightly = oldInfo.LatestNightly
		}
		masterManifest.Devices[newDevice] = existingInfo
	} else {
		masterManifest.Devices[newDevice] = oldInfo
	}
	masterManifest.LastUpdated = time.Now()

	// Write master manifest
	w = masterObj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl
	masterContent, err := json.MarshalIndent(masterManifest, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal master manifest: %w", err)
	}
	if _, err := w.Write(masterContent); err != nil {
		w.Close()
		return fmt.Errorf("failed to write master manifest: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("failed to finalize master manifest: %w", err)
	}

	logger.Info("Successfully renamed device type")
	return nil
}

// removeFirmwareChip removes a firmware chip type from the manifests and optionally deletes its files
func removeFirmwareChip(ctx context.Context, bucket *storage.BucketHandle, chip string, deleteFiles bool) error {
	logger := log.WithFields(logrus.Fields{
		"chip":         chip,
		"delete_files": deleteFiles,
	})
	logger.Info("Removing firmware chip type")

	// Read the master manifest
	masterManifestPath := "manifests/master.json"
	masterObj := bucket.Object(masterManifestPath)

	var masterManifest MasterManifest
	r, err := masterObj.NewReader(ctx)
	if err != nil {
		logger.WithError(err).Error("Failed to read master manifest")
		return fmt.Errorf("failed to read master manifest: %w", err)
	}
	limitedReader := io.LimitReader(r, 10*1024*1024)
	content, err := io.ReadAll(limitedReader)
	r.Close()
	if err != nil {
		logger.WithError(err).Error("Failed to read master manifest content")
		return fmt.Errorf("failed to read master manifest: %w", err)
	}

	if err := json.Unmarshal(content, &masterManifest); err != nil {
		logger.WithError(err).Error("Failed to decode master manifest")
		return fmt.Errorf("failed to decode master manifest: %w", err)
	}

	// Check that the firmware chip exists
	if masterManifest.Firmware == nil {
		logger.Error("No firmware section in master manifest")
		return fmt.Errorf("firmware chip %q not found in master manifest (no firmware section)", chip)
	}
	if _, exists := masterManifest.Firmware[chip]; !exists {
		logger.Error("Firmware chip not found in master manifest")
		return fmt.Errorf("firmware chip %q not found in master manifest", chip)
	}

	// Delete uploaded files if requested
	if deleteFiles {
		prefix := fmt.Sprintf("firmware/%s/", chip)
		logger.WithField("prefix", prefix).Info("Deleting uploaded firmware files")
		deleted, err := deleteObjectsByPrefix(ctx, bucket, prefix)
		if err != nil {
			logger.WithError(err).Error("Failed to delete firmware files")
			return fmt.Errorf("failed to delete firmware files: %w", err)
		}
		logger.WithField("deleted_count", deleted).Info("Deleted firmware files")
	}

	// Delete the firmware manifest
	manifestPath := fmt.Sprintf("manifests/%s.json", chip)
	logger.WithField("manifest_path", manifestPath).Info("Deleting firmware manifest")
	if err := bucket.Object(manifestPath).Delete(ctx); err != nil {
		logger.WithError(err).Warn("Failed to delete firmware manifest (may not exist)")
	} else {
		logger.Info("Deleted firmware manifest")
	}

	// Remove from master manifest and write it back
	delete(masterManifest.Firmware, chip)
	masterManifest.LastUpdated = time.Now()

	w := masterObj.NewWriter(ctx)
	w.CacheControl = manifestCacheControl
	updatedContent, err := json.MarshalIndent(masterManifest, "", "  ")
	if err != nil {
		logger.WithError(err).Error("Failed to marshal master manifest")
		return fmt.Errorf("failed to marshal master manifest: %w", err)
	}

	if _, err := w.Write(updatedContent); err != nil {
		w.Close()
		logger.WithError(err).Error("Failed to write master manifest")
		return fmt.Errorf("failed to write master manifest: %w", err)
	}

	if err := w.Close(); err != nil {
		logger.WithError(err).Error("Failed to finalize master manifest write")
		return fmt.Errorf("failed to finalize master manifest write: %w", err)
	}

	logger.Info("Successfully removed firmware chip type")
	return nil
}
