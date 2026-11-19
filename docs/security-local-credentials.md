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
This locks the password only: an SSH key for `wendy` keeps working, as it does
with the shipped `*` field. To disable the account itself, set its expiry with
`usermod --expiredate 1 wendy`; console, SSH and sudo all refuse an expired
account, and `usermod --expiredate '' wendy` enables it again. Neither replaces
authorization of Agent certificates.

Every login program uses the same PAM stack: `login`, `su`, `sshd` and `sudo`
check the account through `common-auth` and `common-account`, and `passwd`
through `common-password`.

## Updates and recovery

The shipped image owns `/etc/shadow`, so a newly installed A/B root filesystem
starts with the locked entry. What the device owns in the `wendy` entry is
therefore also kept on `/data`, in `/data/etc/wendyos-credential/wendy`,
readable by root only: the password, the day it was last changed, and the
account expiry. It is saved whenever `/etc/shadow` changes, and again at boot
and at shutdown, and it is restored at boot before any login path is open. A
provisioned password, a lock set with `passwd -l`, and an account disabled
with `usermod --expiredate 1 wendy` therefore survive an update. The password
aging limits are not kept: they stay those of the installed image.

To disable the account, use the expiry: every login path honours it. `passwd
-l` locks the password only, as described above.

Each slot records the entry it last had in common with `/data`. At boot the
saved entry is applied to a new slot and to a slot that was rolled back to,
and a change that this slot never managed to save, for example because `/data`
was read-only or power was cut, is kept and saved instead. The old shared
password, an empty password and a hash the account tools would reject are
never saved or restored; setting one removes the saved entry, so the next
installed slot starts locked. If `/data` itself cannot be written, the saved
entry cannot be corrected, and a slot installed in that state receives the
older entry.

The saved entry is lost with `/data`. After a wipe of `/data`, including the
one-time conversion to an encrypted `/data`, the running slot saves its entry
again at the next boot, and only a slot installed before that boot needs to be
provisioned again. A reinstall that keeps `/data` keeps the password. Agent
enrollment is stored under `/var/lib/wendy`, which is mounted from
`/data/wendy` for A/B updates. Verify authenticated Agent access before and
after the update.

This change does not rewrite credentials on a running device, and an image
from before it does not restore the saved entry. The slot that holds the
previous image keeps the legacy shared password until it is overwritten, and a
rollback boots it again. After the first update to a locked image, apply one
more update to overwrite that slot, and validate the recovery process. Systems
with a downstream persistent `/etc/shadow` must remove the legacy shared
credential separately while preserving unique provisioned credentials.

If an unenrolled device has no approved administrative access path, use the
deployment's authorized enrollment or recovery procedure. Do not restore a
shared password to make an image accessible. Operators using an older Agent
without host-shell support must establish a supported provisioning path
before installing this image.

## Debug builds

Images built with `bootstrap.sh --debug` and CI pull-request images set
`WENDYOS_CONSOLE_AUTOLOGIN = "1"`. On these images the serial console and the
screen open a root shell without a login, so a board can still be debugged
when the Agent or the network is down. This adds no credential: the `wendy` and
root passwords stay locked, and SSH still needs a key or a provisioned
password. The build fails if the setting is used without `WENDYOS_DEBUG = "1"`
and an enabled console login, or on a build that CI stamps as nightly or
release (`WENDYOS_BUILD_KIND`). Never deploy an image built with it.

## Assessment evidence

This addresses the shared source credential associated with GPOS
V-203625, V-203627, V-203634, and V-203676. Password quality is enforced on
PAM password changes; privileged raw hash writes such as `usermod -p` or
`chpasswd -e` bypass PAM and are not approved provisioning paths. The boot-time
restore writes back an entry the device already held; it sets no new password.

Record the exact image and Agent release, resolved packages and PAM files,
locked initial account state, rejected weak passwords, accepted unique
credential, login behavior, and A/B update and recovery results. Password
history, aging, MFA, account lifecycle and deployment authorization remain
separate requirements. The included Linux integration test exercises the
password-changing stack; it does not establish compliance of a built device.
