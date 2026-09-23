# Stored-key transient handshake regression

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
19 groups. The separate real ARM64 recipe compile checks the surrounding daemon
APIs and links the actual NetworkManager executable.

The allowance is deliberately narrow: automatic infrastructure activation,
remote reason 15, an existing association deadline, and identical nonempty applied/persistent system-owned PSKs. It is attached to
the activation request so secret-stage reentry cannot reset it. It neither
replays credentials nor starts an extra timer. The existing deadline terminates
this activation with SUPPLICANT_TIMEOUT if recovery has not completed, even
when the distro's auth-retries default is zero. Explicit PSK-mismatch signals,
another reason-15 failure, and user-requested activation keep upstream behavior.
Prior-success history is not required: native OTA replaces the root-local NM
timestamps database. Even a stored wrong key receives only this one chance;
normal authentication still decides success, and second-failure/deadline
regressions prove that an absent mismatch notification cannot cause a loop.

The physical gate remains: a controlled single handshake interruption must
recover automatically without a new-secret request or radio reset, followed
by repeated-failure and changed-key negatives. Preserve NAN-only boot behavior
and verify ordinary user cancellation is respected. This patch mitigates the
observed false-secret classification; it does not establish the underlying RF
timeout's cause.
