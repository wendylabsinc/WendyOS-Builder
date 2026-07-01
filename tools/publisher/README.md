# WendyOS Publisher

A CLI tool for managing OS image manifests and uploads to Google Cloud Storage (GCS). This tool handles versioning, metadata management, and supports advanced features like image swapping and recovery file uploads for embedded device distributions.

> Migrated from [wendylabsinc/wendy-os-publisher](https://github.com/wendylabsinc/wendy-os-publisher) into this repository (`tools/publisher/`) so the publisher and the build workflow that drives it are versioned and reviewed together.

## Overview

The WendyOS Publisher maintains a structured manifest system in GCS for distributing OS images to various device types. It manages:

- **Device-specific manifests** - Version catalogs per device type
- **Master manifest** - Top-level index of all devices and latest versions
- **Image files** - OS images stored in versioned directories
- **Recovery files** - Optional secondary files (e.g., tegraflash packages for Jetson devices)
- **Checksums** - SHA256 integrity verification for all files

## Features

### Core Functionality
- ✅ Upload OS images with automatic manifest updates
- ✅ Device type management (create, configure stability levels)
- ✅ Version management (stable and nightly builds)
- ✅ Automatic latest version tracking
- ✅ List all images in bucket

### Advanced Features
- 🔄 **Image Swap** - Replace existing version's image while preserving metadata
- 📦 **Recovery File Support** - Upload secondary files alongside main images
- 🔐 **SHA256 Checksums** - Automatic integrity verification
- 🚀 **Nightly Promotion** - Convert tested nightly builds to stable releases
- 📊 **Device Stability Levels** - Mark devices as stable, experimental, or deprecated
- 🔑 **Auto Authentication** - Automatic gcloud authentication if credentials missing

## Installation

### Prerequisites
- Go 1.16 or later
- `gcloud` CLI tool (for authentication)
- Access to a GCS bucket

### Build from Source
```bash
cd tools/publisher
go build -o publisher .
```

The compiled binary will be created at `tools/publisher/publisher`.

## Configuration

### GCS Bucket
By default, the tool uses the `wendyos-images-public` bucket. Override with:
```bash
--bucket your-bucket-name
```

### Authentication
The tool automatically triggers `gcloud auth application-default login` if credentials are not found.

## Usage

### Basic Upload

Upload an OS image for a device:
```bash
./upload_and_manifest \
  --device raspberry-pi-5 \
  --version 1.0.0 \
  --file /path/to/wendyos-1.0.0.img
```

This will:
1. Upload the image to `images/raspberry-pi-5/1.0.0/wendyos-1.0.0.img`
2. Calculate SHA256 checksum
3. Update device manifest at `manifests/raspberry-pi-5.json`
4. Update master manifest at `manifests/master.json`
5. Mark version as latest stable release

### Upload with Recovery File

For devices that require recovery packages (e.g., Jetson devices):
```bash
./upload_and_manifest \
  --device jetson-orin-nano-devkit-nvme-edgeos \
  --version 1.0.0 \
  --file /path/to/image.zip \
  --recovery-file /path/to/tegraflash.tar.gz
```

Both files will be uploaded and checksummed. The manifest will contain paths and checksums for both.

### SBOM (Software Bill of Materials)

Attach the image-level SPDX SBOM bundle produced by the Yocto `create-spdx`
class (`.spdx.tar.zst`, found in the image deploy dir):
```bash
./upload_and_manifest \
  --device jetson-agx-orin \
  --version 1.0.0 \
  --file /path/to/image.zip \
  --sbom /path/to/wendyos-image-jetson-agx-orin.spdx.tar.zst
```

The SBOM is uploaded as-is (already compressed, never recompressed) and recorded
in the manifest under `sbom_path` / `sbom_checksum` / `sbom_size_bytes`. It
describes the OS image contents, so it is a single top-level field (not split
per storage variant) and is never treated as a flashable payload.

### Nightly Builds

Upload a nightly/untested build:
```bash
./upload_and_manifest \
  --device raspberry-pi-5 \
  --version nightly-2026-01-29 \
  --file /path/to/nightly.img \
  --nightly
```

Nightly builds:
- Track separately from stable releases
- Have their own "latest" flag
- Can be promoted to stable after testing

### Promote Nightly to Stable

Convert a tested nightly build to a stable release:
```bash
./upload_and_manifest \
  --device raspberry-pi-5 \
  --version nightly-1.0.0 \
  --promote
```

This will:
1. Copy the nightly image to a new stable version (removes "nightly-" prefix)
2. Copy recovery file if present
3. Preserve original release date and metadata
4. Mark as latest stable version
5. Track promotion source in metadata

### Swap Image File

Replace an existing version's image file (e.g., to fix a critical bug) while preserving metadata:
```bash
./upload_and_manifest \
  --device raspberry-pi-5 \
  --version 1.0.0 \
  --file /path/to/fixed-image.img \
  --swap
```

**What's preserved:**
- Original release date
- Changelog
- Latest flag
- Nightly/stable category
- Promotion metadata
- Recovery file (if present)

**What's updated:**
- Image file and path
- File size
- SHA256 checksum
- Swap timestamp
- Swap counter (tracks how many times swapped)

**Validations:**
- Version must exist (fatal if not)
- Cannot change nightly/stable category
- Warns if filename changes

### Create New Device

Initialize manifests for a new device type:
```bash
./upload_and_manifest \
  --device new-device-type \
  --create-device \
  --stability stable
```

Stability levels:
- `stable` - Production-ready devices (default)
- `experimental` - Beta/testing devices
- `deprecated` - End-of-life devices

### Update Metadata Only

Update manifests without re-uploading files:
```bash
./upload_and_manifest \
  --device raspberry-pi-5 \
  --version 1.0.0 \
  --file existing-image.img \
  --update-only
```

Files must already exist in GCS at the expected paths.

### List Images

View all uploaded images:
```bash
./upload_and_manifest --list
```

Output format:
```
Images in bucket:
- Device: raspberry-pi-5
  - Version: 1.0.0
    - wendyos-1.0.0.img
  - Version: 1.0.1
    - wendyos-1.0.1.img
- Device: jetson-orin-nano
  - Version: 1.0.0
    - image.zip
    - tegraflash.tar.gz
```

### Debug Mode

Enable detailed logging:
```bash
./upload_and_manifest --debug [other flags...]
```

## Manifest Structure

### Device Manifest

Located at `manifests/{device-type}.json`:

```json
{
  "device_id": "raspberry-pi-5",
  "versions": {
    "1.0.0": {
      "release_date": "2026-01-29T10:00:00Z",
      "path": "images/raspberry-pi-5/1.0.0/wendyos-1.0.0.img",
      "checksum": "abc123def456...",
      "size_bytes": 1234567890,
      "is_latest": true,
      "is_nightly": false
    },
    "nightly-2026-01-29": {
      "release_date": "2026-01-29T02:00:00Z",
      "path": "images/raspberry-pi-5/nightly-2026-01-29/nightly.img",
      "checksum": "789xyz123abc...",
      "size_bytes": 1234567999,
      "is_latest": true,
      "is_nightly": true
    }
  }
}
```

### Master Manifest

Located at `manifests/master.json`:

```json
{
  "last_updated": "2026-01-29T15:30:00Z",
  "devices": {
    "raspberry-pi-5": {
      "latest": "1.0.0",
      "latest_nightly": "nightly-2026-01-29",
      "manifest_path": "manifests/raspberry-pi-5.json",
      "stability": "stable"
    },
    "jetson-orin-nano": {
      "latest": "1.0.0",
      "latest_nightly": "nightly-1.5.0",
      "manifest_path": "manifests/jetson-orin-nano.json",
      "stability": "experimental"
    }
  }
}
```

### Metadata Fields

#### Version Metadata

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `release_date` | timestamp | Yes | Original upload timestamp |
| `path` | string | Yes | GCS path to main image file |
| `checksum` | string | No | SHA256 checksum of main image |
| `size_bytes` | integer | Yes | Size of main image in bytes |
| `changelog` | string | No | Version changelog/notes |
| `is_latest` | boolean | Yes | Latest version in category (stable/nightly) |
| `is_nightly` | boolean | No | Whether this is a nightly build |
| `promoted_from` | string | No | Source nightly version (if promoted) |
| `promoted_at` | timestamp | No | When promoted to stable |
| `swapped_at` | timestamp | No | When image was last swapped |
| `swap_count` | integer | No | Number of times image was swapped |
| `recovery_path` | string | No | GCS path to recovery file |
| `recovery_checksum` | string | No | SHA256 checksum of recovery file |
| `recovery_size_bytes` | integer | No | Size of recovery file in bytes |

## GCS Storage Structure

```
gs://your-bucket/
├── manifests/
│   ├── master.json                    # Master manifest
│   ├── raspberry-pi-5.json            # Device manifest
│   └── jetson-orin-nano.json          # Device manifest
│
└── images/
    ├── raspberry-pi-5/
    │   ├── 1.0.0/
    │   │   └── wendyos-1.0.0.img
    │   ├── 1.0.1/
    │   │   └── wendyos-1.0.1.img
    │   └── nightly-2026-01-29/
    │       └── nightly.img
    │
    └── jetson-orin-nano/
        └── 1.0.0/
            ├── image.zip
            └── tegraflash.tar.gz      # Recovery file
```

## Use Cases

### Scenario 1: Regular Release
```bash
# Build and upload new stable version
./upload_and_manifest \
  --device raspberry-pi-5 \
  --version 1.1.0 \
  --file builds/wendyos-1.1.0.img
```

### Scenario 2: Nightly Build Pipeline
```bash
# Nightly build automation
./upload_and_manifest \
  --device raspberry-pi-5 \
  --version nightly-$(date +%Y-%m-%d) \
  --file builds/nightly.img \
  --nightly

# After testing, promote to stable
./upload_and_manifest \
  --device raspberry-pi-5 \
  --version nightly-1.2.0 \
  --promote
```

### Scenario 3: Critical Hotfix
```bash
# Version 1.0.0 has a critical bug
# Build fixed image and swap it
./upload_and_manifest \
  --device raspberry-pi-5 \
  --version 1.0.0 \
  --file builds/fixed-1.0.0.img \
  --swap

# Clients will see:
# - Same version number
# - Different checksum (integrity verification)
# - Updated swap_count and swapped_at timestamp
```

### Scenario 4: Jetson Device with Recovery
```bash
# Upload Jetson image with recovery package
./upload_and_manifest \
  --device jetson-orin-nano-devkit-nvme-edgeos \
  --version 1.0.0 \
  --file builds/image.zip \
  --recovery-file builds/tegraflash.tar.gz

# Both files are available to clients
# Each has its own checksum for verification
```

## Client Integration

### Downloading Images

Clients should:
1. Fetch master manifest to find device's manifest path
2. Fetch device manifest to get version list
3. Choose version based on needs (latest stable, latest nightly, specific version)
4. Download image file and recovery file (if present)
5. Verify checksums match manifest values

### Example Client Code

```go
// Fetch device manifest
resp, _ := http.Get("https://storage.googleapis.com/bucket/manifests/raspberry-pi-5.json")
var manifest DeviceManifest
json.NewDecoder(resp.Body).Decode(&manifest)

// Get latest stable version
for version, metadata := range manifest.Versions {
    if metadata.IsLatest && !metadata.IsNightly {
        // Download from metadata.Path
        // Verify checksum matches metadata.Checksum

        // If recovery file exists, also download it
        if metadata.RecoveryPath != nil {
            // Download from *metadata.RecoveryPath
            // Verify checksum matches *metadata.RecoveryChecksum
        }
    }
}
```

## Error Handling

The tool exits with non-zero status on errors:

- **Authentication errors**: Triggers gcloud auth flow
- **Validation errors**: Invalid device names, versions, or file paths
- **GCS errors**: Network issues, permission problems
- **Swap errors**: Version doesn't exist, category mismatch
- **Promotion errors**: Source not nightly, target already exists

All errors are logged with context using structured logging.

## Backward Compatibility

All new features are backward compatible:

- ✅ Old manifests work without migration
- ✅ Old clients ignore new fields (omitempty JSON tags)
- ✅ New clients handle missing fields gracefully
- ✅ Mixed environment support (old and new versions coexist)

## Contributing

This tool is part of the WendyOS distribution infrastructure. For changes:

1. Test locally with a test bucket
2. Verify manifest structure changes are backward compatible
3. Update this README with new features
4. Test client compatibility

## License

Proprietary - Wendy Labs Inc.
