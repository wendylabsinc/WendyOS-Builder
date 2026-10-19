# Legacy advertising expiry regression

Run `python3 tests/bluetooth-advertising/run.py` (Python 3, a C compiler and
`patch`). The runner downloads the four affected files at the shipped Raspberry
Pi kernel revision and applies the shared LE pending fix followed by the actual
advertising patch. `--sources DIR` accepts a cached unpatched kernel tree. Both
downloaded and cached files must match the committed SHA-256 hashes before any
patching or compilation. Update the revision and hashes together.

The harness compiles the actual cleanup, removal, scheduling and scan-expiry
function bodies. Nine additional expiry checks cover queued-work authority via
the retained marker, allocation retry, future/due/zero-delay deadlines, unrelated
markers, unlimited advertising, and both cancellation paths. The expiry harness
intentionally provides no work-list or queue mutex: device-owned expiry state
must answer the predicate without depending on cancellation-held locks.
It checks both expiry cleanup entry points, removal after selection changes or
clears, expiry with lifetime remaining, unrelated expiry markers, a live
replacement's timer ownership, and subsequent scheduling. Removing the new
independent expiry clears must reproduce the stuck-advertising failures.
Kernel workqueue/controller operations are modeled; this test does not replace
full image builds or hardware validation. Update the pinned source revision
when the Raspberry Pi recipe moves.

Allocation/queue failure retries back off from 100 ms to 3.2 seconds while
retaining expiry ownership. The harness checks saturation without counter
wraparound and fresh-slice reset; cleanup is never abandoned after a retry limit.

The existing public-address fallback is intentional: controller limitations may
prevent simultaneous private-address active scanning and legacy advertising.
Bluetooth address privacy is not a Wendy authentication or authorization
boundary, and public addresses may be observable and trackable. Mesh peer
security must continue to rely on authenticated transport and credentials.
