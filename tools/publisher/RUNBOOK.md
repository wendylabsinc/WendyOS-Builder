# WendyOS Image Publishing Runbook

Operational guide for publishing OS images using the WendyOS publisher (`tools/publisher/` in the `wendyos-builder` repository). This covers the day-to-day workflows as they're actually run.

## Prerequisites

- Go 1.16+ installed
- `gcloud` CLI installed and configured
- Access to `wendyos-images-public` GCS bucket
- OS image build artifacts ready (from Yocto build output)

### Authentication

The tool auto-triggers `gcloud auth application-default login` if your credentials are missing or expired. Just follow the browser prompt when it pops up.

You can also pass a token directly with `--access-token` (useful in CI):
```bash
go run . --access-token "$(gcloud auth print-access-token)" [other flags]
```

If you need to manually re-auth:
```bash
gcloud auth application-default login
```

## Running the Tool

All commands are run from `tools/publisher/` in the `wendyos-builder` repository using `go run .`:

```bash
cd ~/wendyos-builder/tools/publisher
go run . [flags]
```

You can also build and run the binary directly:
```bash
cd tools/publisher && go build -o publisher .
./publisher [flags]
```

> **Note:** Both single-dash (`-flag`) and double-dash (`--flag`) work for all flags.

---

## Common Workflows

### 1. Publish a New Nightly Build (Jetson)

This is the most common operation. After building a new Jetson image, publish it as a nightly with the image zip, tegraflash recovery file, and Mender OTA artifact.

```bash
go run . \
  -device jetson-orin-nano \
  -version 0.10.5-nightly \
  -file ~/workspace-meta-wendyos-jetson/deploy/wendyos-0.10.5.img.zip \
  --recovery-file ~/workspace-meta-wendyos-jetson/build/tmp/deploy/images/jetson-orin-nano-devkit-nvme-edgeos/edgeos-image-jetson-orin-nano-devkit-nvme-edgeos-YYYYMMDDHHMMSS.tegraflash.tar.gz \
  --ota-update ~/workspace-meta-wendyos-jetson/build/tmp/deploy/images/jetson-orin-nano-devkit-nvme-edgeos/edgeos-image-jetson-orin-nano-devkit-nvme-edgeos-YYYYMMDDHHMMSS.mender \
  -nightly
```

**Where to find the files:**
- **Image zip:** `~/workspace-meta-wendyos-jetson/deploy/wendyos-<version>.img.zip`
- **Tegraflash recovery:** `~/workspace-meta-wendyos-jetson/build/tmp/deploy/images/jetson-orin-nano-devkit-nvme-edgeos/edgeos-image-jetson-orin-nano-devkit-nvme-edgeos-<timestamp>.tegraflash.tar.gz`
- **Mender OTA:** `~/workspace-meta-wendyos-jetson/build/tmp/deploy/images/jetson-orin-nano-devkit-nvme-edgeos/edgeos-image-jetson-orin-nano-devkit-nvme-edgeos-<timestamp>.mender`

The timestamp in the filenames comes from the Yocto build. Match it to the build you're publishing.

A Discord notification is sent automatically on success. Disable with `--notify-discord=false`.

### 2. Swap a Nightly Build (Hotfix)

When you need to replace a nightly's image (e.g., you rebuilt with a fix but want to keep the same version number):

```bash
go run . \
  -device jetson-orin-nano \
  -version 0.10.4-nightly \
  -file ~/workspace-meta-wendyos-jetson/deploy/wendyos-0.10.4.img.zip \
  --recovery-file ~/workspace-meta-wendyos-jetson/build/tmp/deploy/images/jetson-orin-nano-devkit-nvme-edgeos/edgeos-image-jetson-orin-nano-devkit-nvme-edgeos-<new-timestamp>.tegraflash.tar.gz \
  -nightly \
  -swap
```

This preserves the version's metadata (release date, changelog) but replaces the actual files and updates checksums. The `swap_count` increments each time.

> **Tip:** You can swap multiple times. This was done frequently during 0.10.4-nightly development (swapped 4+ times as fixes landed).

### 3. Promote a Nightly to Stable

> **CI nightlies (`nightly-YYYYMMDDTHHMMSS`) are NOT promoted with this tool.**
> They don't embed a semantic version, so there is nothing to strip the
> `nightly` marker from (the tool refuses with an error). Promote them by
> running the **"Promote Nightly to Release"** GitHub workflow, which tags the
> commit `MAJOR.MINOR.PATCH` and rebuilds/publishes the real version.

For legacy `X.Y.Z-nightly` versions, after testing on devices:

```bash
go run . \
  -device jetson-orin-nano \
  -version 0.10.4-nightly \
  -promote
```

This:
- Copies the image, recovery file, and OTA artifact to a new stable path (`0.10.4-nightly` becomes `0.10.4`)
- Marks it as the latest stable version
- Records the promotion source in metadata

### 4. Publish a Stable Release Directly

If you're confident in the build and want to skip the nightly phase:

```bash
go run . \
  -device jetson-orin-nano \
  -version 0.10.5 \
  -file ~/workspace-meta-wendyos-jetson/deploy/wendyos-0.10.5.img.zip \
  --recovery-file ~/workspace-meta-wendyos-jetson/build/tmp/deploy/images/jetson-orin-nano-devkit-nvme-edgeos/edgeos-image-jetson-orin-nano-devkit-nvme-edgeos-<timestamp>.tegraflash.tar.gz \
  --ota-update ~/workspace-meta-wendyos-jetson/build/tmp/deploy/images/jetson-orin-nano-devkit-nvme-edgeos/edgeos-image-jetson-orin-nano-devkit-nvme-edgeos-<timestamp>.mender
```

No `-nightly` flag = stable release.

### 5. Upload with Only Some Artifacts

You don't have to provide all three files. At least one of `--file`, `--ota-update`, or `--recovery-file` is required.

OS image only (e.g., early Jetson uploads before recovery/OTA support):
```bash
go run . \
  -device jetson-orin-nano \
  -version 0.9.8 \
  -file ~/jetson/Linux_for_Tegra/wendyos-jetson-20251208-134038.img.zip
```

OTA update only (add a Mender artifact to an existing version):
```bash
go run . \
  -device jetson-orin-nano \
  -version 0.10.5 \
  --ota-update ~/workspace-meta-wendyos-jetson/build/tmp/deploy/images/jetson-orin-nano-devkit-nvme-edgeos/edgeos-image-jetson-orin-nano-devkit-nvme-edgeos-<timestamp>.mender
```

### 6. List All Published Images

```bash
go run . --list
```

### 7. Create a New Device Type

Before uploading images for a new device, create its manifest entry:

```bash
go run . \
  -device raspberry-pi-5 \
  -create-device \
  -stability experimental
```

Stability levels: `stable`, `experimental`, `deprecated`

---

## Discord Notifications

Successful publishes automatically send a notification to the team Discord channel with:
- Device type and version
- Whether it's a nightly or stable release
- File sizes for OS image, OTA update, and recovery file
- Total upload size and timestamp

This is on by default. To suppress:
```bash
go run . [flags] --notify-discord=false
```

---

## Smart Compression

The tool automatically compresses files before upload based on type:
- `.img` files get compressed (xz)
- `.mender` files get maximum compression (xz-max)
- Already-compressed files (`.zip`, `.tgz`, `.tar.gz`) are uploaded as-is

---

## Post-Upload Verification

After uploading, the tool automatically verifies:
- Manifest entries match what was uploaded (paths, checksums)
- Files exist at the expected GCS paths
- Retries verification once on failure before reporting an error

---

## Typical Release Cycle

The typical flow for Jetson releases:

```
1. Build image in Yocto workspace
2. Publish as nightly:    go run . -device jetson-orin-nano -version X.Y.Z-nightly \
                            -file ... --recovery-file ... --ota-update ... -nightly
3. Flash device and test
4. If bugs found, rebuild and swap: go run . ... -swap
5. Repeat 3-4 until stable
6. Promote to stable:    go run . -device jetson-orin-nano -version X.Y.Z-nightly -promote
```

### Version Naming Convention

- **Nightly (CI):** `nightly-YYYYMMDDTHHMMSS` (e.g., `nightly-20260604T163205`, UTC; sorts chronologically)
- **Stable:** `X.Y.Z` (e.g., `0.10.5`) — never a `v` prefix
- **Nightly (legacy):** `X.Y.Z-nightly` (e.g., `0.10.4-nightly`)
- **Date-based nightly (legacy):** `nightly-YYYY-MM-DD`

---

## File Paths Reference

### Build Artifacts (Jetson)

| Artifact | Path |
|----------|------|
| Image zip | `~/workspace-meta-wendyos-jetson/deploy/wendyos-<version>.img.zip` |
| Tegraflash recovery | `~/workspace-meta-wendyos-jetson/build/tmp/deploy/images/jetson-orin-nano-devkit-nvme-edgeos/edgeos-image-...-<timestamp>.tegraflash.tar.gz` |
| Mender OTA | `~/workspace-meta-wendyos-jetson/build/tmp/deploy/images/jetson-orin-nano-devkit-nvme-edgeos/edgeos-image-...-<timestamp>.mender` |

### GCS Layout

```
gs://wendyos-images-public/
  manifests/
    master.json
    jetson-orin-nano.json
  images/
    jetson-orin-nano/
      0.10.5/
        wendyos-0.10.5.img.zip
        tegraflash.tar.gz
        edgeos-image-...-<timestamp>.mender
      0.10.5-nightly/
        wendyos-0.10.5.img.zip
        tegraflash.tar.gz
        edgeos-image-...-<timestamp>.mender
```

---

## All Flags Reference

| Flag | Required | Description |
|------|----------|-------------|
| `--device <name>` | Yes (most ops) | Device type identifier (e.g., `jetson-orin-nano`) |
| `--version <ver>` | Yes (most ops) | Version string (e.g., `0.10.5`, `0.10.5-nightly`) |
| `--file <path>` | Conditional | Local path to the OS image file |
| `--ota-update <path>` | No | Local path to Mender OTA update file (`.mender`) |
| `--recovery-file <path>` | No | Local path to recovery/tegraflash file |
| `--bucket <name>` | No | GCS bucket (default: `wendyos-images-public`) |
| `--nightly` | No | Mark this build as a nightly |
| `--swap` | No | Replace existing version's files, keep metadata |
| `--promote` | No | Promote a nightly version to stable |
| `--create-device` | No | Create a new device entry in manifests |
| `--stability <level>` | No | Device stability: `stable`, `experimental`, `deprecated` |
| `--update-only` | No | Update manifests without uploading files |
| `--list` | No | List all images in the bucket |
| `--notify-discord <bool>` | No | Send Discord notification (default: `true`) |
| `--access-token <token>` | No | GCS access token (for CI or manual override) |
| `--debug` | No | Enable verbose debug logging |
| `--help` | No | Show help message |

At least one of `--file`, `--ota-update`, or `--recovery-file` is required for upload operations.

---

## Troubleshooting

### "authentication error" on first run
The tool will auto-open a browser for Google auth. Complete the login flow and the upload will retry. Alternatively, pass `--access-token` directly.

### "version does not exist" on swap
The `--swap` flag requires an existing version. Check you're using the exact version string (including `-nightly` suffix if applicable).

### "cannot change nightly/stable category" on swap
You can't swap a nightly build without the `-nightly` flag, or vice versa. The category must match the original upload.

### Upload seems stuck
Large image zips (2-4GB) take time. The progress bar should be updating. If it stalls, check your network connection and re-run.

### Discord notification failed
The upload still succeeded -- notification failures are non-fatal warnings. Check network connectivity if it persists.

### Need to see what's published
```bash
go run . --list
```
Or check the manifests directly in GCS:
```bash
gsutil cat gs://wendyos-images-public/manifests/master.json | python3 -m json.tool
gsutil cat gs://wendyos-images-public/manifests/jetson-orin-nano.json | python3 -m json.tool
```
