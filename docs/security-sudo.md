# Local administrator authentication

The shipped sudo policy requires the `wendy` account's own authenticator for
every invocation. It does not cache successful authentication, including
`sudo -v`. The direct Runas grant is limited to root. The account remains a full
host administrator after authentication; this is not a restricted operator role.

Before relying on local or SSH administration, provision an individual strong
password for the account through an already authorized administrative channel.
A locked account or an account with only an SSH public key cannot satisfy this
password authentication path. Do not distribute one password across devices or
bake one into a reusable image. The separate local-credential change documents
the provisioning path and password policy. Deploy that change together with this
policy: requiring a password does not secure an image that still ships a shared
default password.

This changes existing workflows. `sudo -n` and unattended SSH commands that
assumed passwordless sudo now fail. Use the authorized Wendy Agent management
operations for automation. If a new unattended privileged operation is needed,
implement and review a dedicated service with constrained inputs and privileges;
do not restore `NOPASSWD: ALL`. Existing root systemd services do not use this
sudo rule.

A root shell obtained after authentication remains privileged until it exits.
This policy requires authentication on entry and does not provide a session idle
timeout, MFA, separate named administrator accounts, or audit retention. Downstream
sudoers rules and PAM configuration can change the effective result and must be
included in deployment assessment.

## Validation

Run the real sudo/PAM behavior checks in a disposable Linux container:

```sh
docker build -f tests/sudo-policy/Dockerfile -t wendy-sudo-policy-test .
docker run --rm --hostname localhost --network none wendy-sudo-policy-test
```

The tests check successful caller authentication with root locked, rejected
incorrect credentials, a locked account, an unrelated user, direct Runas to an
ungranted user, and rejection of cached authentication after both a command and
`sudo -v`. They do not modify the developer host's users or sudoers files.

This addresses the source policy behind GPOS V-203723,
SRG-OS-000373-GPOS-00156. The container tests use Debian's sudo and PAM; closing a
deployed-image finding requires repeating the checks on each supported WendyOS
image with its effective PAM configuration and full sudoers policy. Verify the
provisioning and recovery path before deploying an image with this change.
