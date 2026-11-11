# US Government access notice

Select this profile only for an authorized US Government deployment:

```bitbake
require conf/distro/include/usg-access-notice.inc
```

It addresses the notice and explicit acknowledgement mechanisms in GPOS SRG
V3R4 V-203595 and V-203596. It is not a complete STIG baseline or evidence of
deployed compliance. Ordinary WendyOS images retain their existing login behavior.

The profile adds PAM support, the Shadow login implementation, and a PAM module
that displays the full USG notice and requires the exact response `ACCEPT`.
Anything else, including an empty response, cancelled conversation or missing
notice, denies access. The account check also denies paths that skipped the
consent step, such as a preauthenticated `login -f` invocation.

The notice is a separate root-owned file under `/usr/share/wendyos-access-notice`.
Console branding and build provenance in `/etc/issue` do not replace or alter it.
It uses the full text published in the [DISA GPOS V3R4 source package](https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_GPOS_V3R4_SRG.zip).

## Local console

Existing VT/UART enablement flags still select whether a login interface exists.
For an enabled Shadow login, acceptance precedes password authentication. The
profile does not create credentials, enable root login or enable a getty.
Provision the user's authentication separately. Password and account controls
remain in the usual PAM stacks.

## SSH

When OpenSSH is installed, both its ordinary and read-only-rootfs configurations
require `publickey,keyboard-interactive:pam`. The public key authenticates the
caller, then PAM collects consent before granting access. Existing PAM account,
password-change and session checks remain active. Consent is not an additional
authentication factor and must not be represented as MFA.

**This opt-in profile blocks unattended SSH clients.** Provision authorized keys
before rollout and use a client supporting keyboard-interactive authentication.
BatchMode, password-only and public-key-only connections cannot bypass consent.
Omitting a PTY does not bypass it either. SCP, SFTP, remote commands and forwarding
use the same authentication gate. Do not automatically exempt these modes or
service account names. A separate approved machine-to-machine access design is
required if the deployment needs unattended SSH.

Connection multiplexing reuses an already accepted authenticated connection.
Assess connection/session lifetime separately. This change does not implement
session timeout, smart-card authentication, MFA, or credential provisioning.

## Deployment evidence

Before release, boot each selected board/profile and record:

- Effective `/bin/login` alternative and login PAM configuration.
- Effective `sshd -T` for ordinary and read-only-rootfs services, including any
  deployment-specific `Match` blocks, command-line settings or local overrides.
- Full notice, explicit acceptance and access denial for cancellation or refusal
  on enabled serial, VT and SSH paths.
- Denial with BatchMode and public-key-only authentication. Verify `ssh -T`
  still requires consent, and succeeds only after key authentication and acceptance.
- Expired/disabled account denial and normal PAM password/session behavior.

The image check rejects missing notice files, a different login implementation,
and missing initial PAM/OpenSSH settings. It does not prove runtime configuration
after provisioning or protect against a privileged administrator changing files.

Wendy Agent RPCs, Cloud/CLI application sessions, web interfaces, recovery shells,
and third-party login services are outside this PR. Inventory those paths and
implement their own notice/acknowledgement where they expose human logon access.
Do not mark V-203595 or V-203596 closed for the entire device from this profile
alone.

## Development checks

From the repository root:

```sh
python3 tests/access-notice/recipe_test.py
docker build -f tests/access-notice/Dockerfile -t wendy-access-notice-test .
docker run --rm wendy-access-notice-test
```

The container exercises real Linux-PAM, local `login` and OpenSSH with disposable
accounts and keys. It never changes the development host's authentication files.
The recipe tests exercise install functions and invalid assembled-image fixtures.
These checks do not replace a Yocto image build and board login tests.
