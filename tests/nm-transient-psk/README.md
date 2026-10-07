# Retry saved Wi-Fi after authentication failures

An unattended WendyOS device can stop trying Wi-Fi after a temporary handshake
failure, even when its saved password is correct. NetworkManager asks for a
replacement password, gets no answer, and reports `NO_SECRETS`. Upstream also
blocks that profile from autoconnect, beyond the normal retry cooldown.

The patch changes only that last policy decision. If an infrastructure Wi-Fi
profile still has a nonempty, system-owned WPA-PSK or SAE password, `NO_SECRETS`
counts as an ordinary autoconnect failure. The usual retry budget and cooldown apply:
with upstream defaults, four failures exhaust the budget, then a five-minute
cooldown makes the profile eligible again. Authentication, handshake recovery,
failure reporting and WendyOS's existing `auth-retries=0` setting stay unchanged.
That setting controls authentication attempts within an activation; it is
separate from the autoconnect budget. This patch imposes no activation deadline.

The check reads the saved profile because authentication may already have cleared
the working copy's password. It does not require a successful-connection timestamp:
OTA can replace that database while preserving profiles. It also does not prove
that the password is correct. A retained profile with a wrong password can retry
later; the Wendy agent already attempts to delete newly created profiles when
interactive setup fails. Existing profiles remain available for later reconnection.

The scope is NM's `wpa-psk` (WPA2/WPA3 Personal) and `sae` (WPA3-only) profile
types. Enterprise/other security, non-infrastructure modes, missing keys and keys
marked agent-owned, not-saved or not-required keep upstream
behavior. Autoconnect must still be enabled; user disconnect, profile deletion
and other independent blocks remain effective. The patch does not fix the radio
fault or change the error reported to callers.

## Regression harness

Run with a C compiler, `patch`, Python, `pkg-config` and GObject development files
(`libglib2.0-dev` on Debian/Ubuntu):

```sh
python3 tests/nm-transient-psk/run.py --upstream /path/to/NetworkManager-1.56.0 --output /new/results
python3 tests/nm-transient-psk/run.py --fetch-upstream --output /new/results
```

The runner pins NetworkManager 1.56.0 commit
`56b51b98fbb8627c4c09a483702e18fd8aee7ce1` and verifies `nm-policy.c`'s SHA-256
before applying the recipe patch. It compiles the complete production `FAILED`
case, the saved-key predicate and the existing cooldown callbacks. Surrounding
settings/manager services and time are stubs: this checks the policy's decisions,
retry accounting calls and timer scheduling, not a complete daemon activation.

Four regression groups fail on pristine upstream and pass with the patch: saved
keys use ordinary retry accounting, and repeated exhausted budgets schedule
cooldown/reset/recheck cycles, for both WPA-PSK and SAE. Ten control groups pass
on both: missing keys, secret flags, security types, modes, device types, activation-state bounds,
new-agent registration, other failures, zero/infinite budgets and existing blocks.
Source hashes and individual test logs are retained. The existing path-filtered
CI workflow runs this small check without a Yocto build.

## Hardware validation

Use a controlled AP with a disposable password and an Ethernet-managed client.
Compare pristine and patched NM with the same stock Wi-Fi plugin. Suppress AP
handshake message 3 to provoke the original failure with a correct saved key;
also test a wrong key and an explicit SAE profile on a WPA3 AP. Confirm
`NO_SECRETS` is still reported, the saved key is preserved, and only the candidate
retries after exhausting the normal budget and
waiting through the full cooldown. Restore the AP during cooldown and confirm
automatic reconnection without changing the client profile. Test failed first-time
CLI setup/profile deletion and user cancellation, then restore both devices.

The previous hardware results for custom inner retries do not validate this
replacement policy patch. Fresh validation of this version is still pending.
