# Local credentials

New WendyOS images create `wendy` with a locked password. There is no shared
password, including in debug images. Enabling a console or SSH listener does
not unlock the account. Root remains locked for direct login.

## Provision an individual device

Before depending on local password access, enroll the device and verify that
an authorized operator can open its authenticated Agent host shell. Use a CLI
and Go Agent release that support `wendy device shell`. From a terminal:

```sh
wendy device shell -- passwd wendy
```

Select the intended device using the CLI's device selection options. Enter a
unique password at the prompts, never as a command argument, environment
variable, image build variable, or committed file. The Agent's host shell runs
as root and requires authenticated mTLS operator access; this procedure does
not depend on the locked local password or sudo.

The password-changing PAM stack requires at least 15 characters and at least
one uppercase letter, lowercase letter, digit, and other character. These
checks also apply when root runs `passwd`. `pam_unix` consumes the password
already checked by `pam_pwquality`. The image includes Shadow's PAM-enabled
`passwd`, rather than relying on the BusyBox implementation.

Verify password login on the enabled console or SSH path before ending the
administrative session. SSH key authentication is a separate policy; a key
does not supply the password required by authenticated sudo. The sudo policy
must be assessed separately.

To disable local password authentication again, use the authenticated host
shell to run `passwd -l wendy`. Check the account with `passwd -S wendy`.
Account locking does not replace authorization of other credentials such as
SSH keys or Agent certificates.

## Updates and recovery

The shipped image owns `/etc/shadow`. The standard persistent `/etc` bind
mounts do not preserve it across installation of a new A/B root filesystem.
A password set on one slot survives a reboot into that slot but must be
provisioned again after booting a newly installed image. Agent enrollment is
stored under `/var/lib/wendy`, which is mounted from `/data/wendy` for A/B
updates. Verify authenticated Agent access before and after the update.

This change does not rewrite credentials on a running device. Booting an old
rollback slot can restore its old credential state. Before deployment, update
or retire slots containing the legacy shared password and validate the
recovery process. Systems with a downstream persistent `/etc/shadow` must
remove the legacy shared credential separately while preserving unique
provisioned credentials.

If an unenrolled device has no approved administrative access path, use the
deployment's authorized enrollment or recovery procedure. Do not restore a
shared password to make an image accessible. Operators using an older Agent
without host-shell support must establish a supported provisioning path
before installing this image.

## Assessment evidence

This addresses the shared source credential associated with GPOS
V-203625, V-203627, V-203634, and V-203676. Password quality is enforced on
PAM password changes; privileged raw hash writes such as `usermod -p` or
`chpasswd -e` bypass PAM and are not approved provisioning paths.

Record the exact image and Agent release, resolved packages and PAM files,
locked initial account state, rejected weak passwords, accepted unique
credential, login behavior, and A/B update and recovery results. Password
history, aging, MFA, account lifecycle and deployment authorization remain
separate requirements. The included Linux integration test exercises the
password-changing stack; it does not establish compliance of a built device.
