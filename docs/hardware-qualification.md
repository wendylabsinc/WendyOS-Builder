# Hardware qualification before promotion

An OS build uploads versioned candidate artifacts and writes their device
metadata with the previous qualified latest markers preserved. It does not
advance a stable or nightly master-manifest pointer until
the required rack suite succeeds. Driver build failure, missing rack hardware,
missing Docker, failed OTA, a reboot into the wrong build, and failed app tests
all leave the previous channel pointers in place. Partial build matrices do not
publish candidates or qualify for promotion.

The pipeline runs in this order:

1. Resolve the builder source ref to a commit and use it for every build.
2. Upload images and manifest-entry artifacts for that exact build.
3. Write per-version device metadata and build the matching driver add-ons.
4. Run the WendyOS reusable hardware workflow against these candidate artifacts.
5. Mark candidate device versions latest and advance master-manifest pointers
   after hardware qualification succeeds. Missing candidate metadata or driver
   add-ons aborts the whole promotion before it changes any master pointer.
6. Create the nightly GitHub release, publish any stable release draft, attach
   SBOMs, and announce the qualified version.

The required rack matrix gates the whole nightly. It includes Raspberry Pi,
Jetson, Qualcomm, and generic Linux x86 runtime coverage. The gate installs the
exact matching OS artifact on each WendyOS rack board; it does not claim that
all other board and storage variants were hardware-tested. A generic Linux
runner with a vendor OS receives the candidate Wendy agent and app/runtime tests.
Its OS remains a vendor baseline; it is never flashed with a WendyOS image.
The test evidence states these limits.

## Candidate identity

Every `manifest-entry-*.json` artifact carries `version`, `build_sha`,
`build_storage`, `device`, optional `aliases`, and the OTA path, byte size, and
SHA256. The caller passes its repository and run ID to the reusable workflow.
The test runner downloads the current run's metadata, selects the exact reported
board and storage medium, downloads the versioned `.wendy` bytes from the public
image bucket, verifies size and SHA256, and installs that local verified file.
It never resolves the moving `latest_nightly` pointer to choose its candidate.

The image carries these rootfs records:

- `/usr/lib/wendyos/commit` identifies the resolved builder commit.
- `/usr/lib/wendyos/build-version` identifies the specific candidate build.
- `/usr/lib/wendyos/agent-sha256` identifies the agent shipped in the image.

Qualification checks these records after reboot and again after the app suite.
It compares the bundled agent digest with both the installed binary and the
running process. A rollback or a background agent replacement fails the gate.
The user-facing `osVersion` alone is insufficient because several nightlies can
share the same distribution version.

## Cross-repository rollout

Land the WendyOS `integration-tests.yml` interface and its candidate preparation
helper first, then land this builder change. The reusable workflow is pinned to
WendyOS commit `6f3535bef440992f0d8c119f3dc0f96458e5ee92`. Keep this pin aligned with
reviewed interface changes. The builder resolves the WendyOS main source commit
once at the start of each run and passes it as `source_ref`, so all test jobs use
identical source files. The companion WendyOS change must be merged first so
that main contains the candidate preparation helpers.

The required workflow inputs are `source_ref`, `os_candidate_version`,
`os_candidate_sha`, `os_candidate_repository`, and `os_candidate_run_id`. The
reusable workflow must use its explicit WendyOS checkout rather than the caller
repository, which is the default for `actions/checkout` in a reusable workflow.

The workflow needs the existing organization runner group to allow
`wendyos-builder`, and WendyOS reusable-workflow access to allow this caller.
There is no new cloud secret. Candidate payloads are already public, and the
calling run's `GITHUB_TOKEN` with `actions: read` downloads its own metadata
artifacts. The existing enrolled runner credentials provide authenticated
hardware access. Neither the patch nor its local tests installs an OS on a rack
board; the first CI run validates that wiring.
