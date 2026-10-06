# Stored-key WPA2 handshake recovery

A headless WendyOS device can lose Wi-Fi after a transient WPA2 handshake failure
although its saved password is correct. The supplicant can emit `PskMismatch`
before a remote reason-15 disconnect. Upstream NetworkManager interprets that
heuristic as a request for a replacement password; with no secret agent available,
activation fails with `NO_SECRETS`, which can also block autoconnect.

The patch retains matching, nonempty, system-owned stored/applied WPA-PSK keys
(secret flags `NONE` on both) during infrastructure association. It guards both
notifications, in either order and across repeated failures, while the existing
association timer runs. It covers autoconnect and explicit `connection up`, since
first-boot provisioning and unattended services can activate profiles explicitly.
Individual events neither reset the timer nor consume the retry budget.

At association timeout, NetworkManager's existing cached-secret recovery path is
used, with at most two retries per activation request: three association windows
in total, subject to any smaller configured `auth-retries` budget. The counter
survives secret-stage reentry. This avoids immediately discarding upstream's
recovery for previously successful connections, but still bounds a bad-password
attempt with WendyOS's `auth-retries=0` (unlimited upstream). This is a window
count, not a wall-clock guarantee across asynchronous activation stages.
Exhaustion reports `SUPPLICANT_TIMEOUT` with a diagnostic, and normal autoconnect
retry limits/backoff remain in charge. If the SSID was not seen, the existing
`SSID_NOT_FOUND` diagnosis is preserved. Cancellation does not start recovery.

Prior-success timestamps are not required: OTA can replace the root-local NM
timestamp database while preserving saved profiles. Matching keys establish
consistency, not validity. `PskMismatch` has no disconnect reason, so its guard
also covers a genuinely wrong saved password. Such a password fails within the
bounded windows and must be edited or replaced by the caller. This intentionally
includes newly saved system-owned passwords. WPA authentication is never bypassed.
Agent-owned/unsaved keys, absent or changed applied keys, enterprise/other security,
other modes, and disconnect reasons other than remote reason 15 keep upstream
behavior. A later, independently meaningful disconnect reason can therefore still
request new credentials. The patch does not fix the underlying radio fault.

## Regression harness

Run on Linux with a C compiler, `patch`, Python, `pkg-config` and GObject development
files (`libglib2.0-dev` on Debian/Ubuntu). Choose either a local pristine tree or a
single-file download:

```sh
python3 tests/nm-transient-psk/run.py --upstream /path/to/NetworkManager-1.56.0 --output /new/results
python3 tests/nm-transient-psk/run.py --fetch-upstream --output /new/results
```

The runner pins NetworkManager 1.56.0 commit
`56b51b98fbb8627c4c09a483702e18fd8aee7ce1` and verifies the source file's SHA-256
before applying the recipe patch. It compiles complete production callback bodies,
including the shared predicate; it does not copy their decisions into Python.
GObject request storage is real. Surrounding NM services are recording stubs:
applied-key clearing is modeled, but cached-secret delivery, real auth-retry
accounting, D-Bus ordering and timer scheduling require daemon/hardware validation.
The stubbed authentication helper records whether a new or cached secret was
requested; tests explicitly model configuration reentry on the same request.

Twelve groups run individually on baseline and candidate. Six recovery groups must
fail with assertions on upstream and pass with the patch: repeated events in both
orders, explicit saved-profile activation, all timestamp states, bounded wrong-key
retries across reentry, a smaller auth budget, and missing-SSID diagnosis after a
mismatch. Six control groups must pass on both: cancellation, excluded keys, other
modes/security/disconnect reasons, and already-connected state. Logs and source
hashes are retained in the new output directory. The harness alone does not prove
physical reconnection or a global absence of retry loops.

The path-filtered `nm-transient-psk.yml` workflow runs this check only for changes
to the NM layer, harness or workflow. It downloads one pinned C file, not a Yocto
build or a full source archive, and retains failure evidence as a CI artifact.

## Hardware validation

Use a controlled WPA2-only AP with a disposable password and a client managed over
Ethernet. Establish ordinary connectivity, then suppress AP handshake message 3
for the client to provoke a real reason-15 timeout with the correct key. Compare
unpatched and candidate daemon behavior, including mismatch-before-disconnect.
Test transient and repeated interruptions, explicit activation and autoconnect,
recovery after an association deadline, wrong-key exhaustion with `auth-retries=0`,
and cancellation. Check usable connectivity, failure reasons, preservation of
stored credentials, and restoration of the original radio/service/profile state.

Fresh validation on 2026-10-06 used a Pi5/BE202 as the temporary WPA2-PSK/CCMP AP
and an AGX Thor as the client, with Ethernet management. Both the daemon and
Wi-Fi plugin were rebuilt with the recipe's ARM64 toolchain; the exact patched
source matched the harness source. The client supplicant was left unchanged.

| Hardware case | Result |
| --- | --- |
| Unpatched NM, ordinary WPA2 | Connected successfully. |
| Unpatched NM, correct key with message 3 dropped | Mismatch arrived before disconnect; activation failed with `NO_SECRETS`. |
| Candidate, explicit saved-profile activation, transient loss | Retained the key on both events, connected in 19.1 s, and passed ping. |
| Candidate, autoconnect, fresh profile with timestamp 0, repeated loss | Survived three handshake failures and one association deadline; reused the saved key and connected in 41.8 s, then passed ping. |
| Candidate, genuinely wrong saved key, `auth-retries=0` | Two cached retries, then `SUPPLICANT_TIMEOUT` at 75.4 s; never connected and preserved the stored key. |
| Candidate, cancel after mismatch | Stayed disconnected beyond the former deadline, without a retry or activation. |

These timings describe this test's 25-second association windows, not a product
wall-clock guarantee. Hardware exercised the mismatch-first ordering; reversed
ordering, missing-SSID diagnosis, smaller auth budgets and eligibility exclusions
are covered by the exact-source harness. Installed binaries and original network
profiles were preserved. The temporary AP/overrides were removed and normal Wi-Fi
and NAN operation restored; the Pi5's two NAN apps restarted during restoration.
