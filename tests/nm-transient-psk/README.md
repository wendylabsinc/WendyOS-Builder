# Stored-key transient handshake regression

During automatic Wi-Fi activation, a remote reason-15 four-way handshake timeout
can make NetworkManager clear the applied password and ask for a new one. A
timeout alone does not establish that the saved password is wrong. On an unattended
WendyOS device, this can interrupt reconnection after a reboot or OTA despite an
unchanged password.

The patch skips this false-secret classification once per activation request. It
requires automatic infrastructure activation, WPA-PSK key management, a running
association timer, and identical nonempty stored and applied system-owned PSKs
(secret flags `NONE` on both). It preserves the current credentials and timer so
the supplicant can continue its existing recovery behavior. It does not explicitly
launch a retry, extend the timer, reset the radio or bypass WPA authentication.

The allowance remains consumed across secret-stage reentry. A second handshake
failure or an explicit PSK-mismatch notification follows the upstream
credential-request path, which cancels the current timer and can restart
configuration with another timer after obtaining secrets. Once the allowance has
been used, any association timeout on that same request fails with
`SUPPLICANT_TIMEOUT` instead of re-entering authentication retries, including when
the distro's `auth-retries` default is zero. This is not an immutable deadline
across all stages of the request, nor a limit on NetworkManager's separate
autoconnect retry policy. A genuinely new activation request has a new allowance.

Manual activation, enterprise/other key management, other disconnect reasons,
mesh/AP/ad-hoc modes, and agent-owned, unsaved or absent/changed keys retain
upstream behavior. Cancellation does not trigger recovery. Prior-success history
is not required: native OTA can replace the root-local NM timestamp database
while preserving the profile. Matching stored and applied passwords establishes
consistency, not validity; even a saved wrong password can receive the allowance,
and normal WPA authentication still decides success.

This tests the NetworkManager 1.56.0 recipe source (commit
`56b51b98fbb8627c4c09a483702e18fd8aee7ce1`). Supply an unmodified source tree:

```sh
python3 tests/nm-transient-psk/run.py --upstream /path/to/NetworkManager-1.56.0 --output /new/results
```

Run on Linux with a C compiler, `patch`, Python, and GObject development files.
The output directory must not already exist. No network, real supplicant, or
device access is used. The harness uses a literal test secret only.

The test applies the recipe patch and compiles the complete production bodies
of the PSK heuristic, authentication-failure handler, explicit mismatch handler,
and association-timeout callback. The new helper is extracted unchanged too.
NM platform and secret-agent functions are recording stubs; GObject request
storage is real. This is a source-handler regression, not a D-Bus integration
test or proof of physical reconnect success. Baseline must compile successfully
and abort on the first expected recovery assertion; the candidate must pass all
19 groups. The groups check eligibility exclusions, preserved credentials/timer,
the consumed request allowance, second-failure and explicit-mismatch handling,
and the fatal timeout path. The reentry case reuses request storage; it does not
execute the real secret callback or configuration-stage timer scheduling. The
harness therefore does not prove a fixed request-wide deadline, every possible
secret-agent sequence, or a global absence of retry loops. A separate historical
ARM64 recipe compile checked the surrounding daemon APIs and linked the actual
NetworkManager executable; running this harness does not repeat that build.

The physical gate remains: a controlled single handshake interruption must
recover automatically without a new-secret request or radio reset, followed
by repeated-failure and changed-key negatives. Preserve NAN-only boot behavior
and verify ordinary user cancellation is respected. This patch mitigates the
observed false-secret classification; it does not establish the underlying RF
timeout's cause.
