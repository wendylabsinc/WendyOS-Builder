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
This locks the password only: console login and sudo are refused, but an SSH
key for `wendy` keeps working, as it does with the shipped `*` field. To refuse
SSH as well, remove `/home/wendy/.ssh/authorized_keys`. Neither replaces
authorization of Agent certificates.

Do not disable `wendy` with an expiry date (`usermod --expiredate`) on a device
that runs apps. `wendy` also runs the user session that provides audio to apps,
and an expired account cannot start it, so app audio stops from the next boot.
`usermod --expiredate '' wendy` enables the account again.

Every login program uses the same PAM stack: `login`, `su`, `sshd` and `sudo`
check the account through `common-auth` and `common-account`, and `passwd`
through `common-password`.

## Updates and recovery

The shipped image owns `/etc/shadow`, so a newly installed A/B root filesystem
starts with the locked entry. What the device owns in the `wendy` entry is
therefore also kept on `/data`, in `/data/etc/wendyos-credential/wendy`,
readable by root only: the password, the day it was last changed, and the
account expiry. A watcher checks `/etc/shadow` every two seconds and saves any
change, retrying a save that fails; the entry is also saved at boot and at a
clean shutdown, and it is restored at boot before any login path is open. A
provisioned password, a lock set with `passwd -l`, and an account expiry
therefore survive an update. After an OS update the Agent restarts the device
without a clean shutdown, so a change made in the last few seconds before that
restart, or one that could not be saved yet, does not reach the new slot: it is
saved only if the slot it was made on boots again before another slot saves.
The password aging limits are not kept: they stay those of the installed image.

Every write of the saved entry carries a new random token, and each slot
records its own entry and the token from its last save or restore. At boot:

- A new slot, or a slot whose recorded token differs from the saved one,
  takes the saved entry. Another slot saved since, and that slot was booted
  later, so its entry is the newer one.
- A slot whose recorded token still matches keeps its own entry. A change it
  never managed to save, for example because power was cut, is saved then.
- A slot that saved before but finds the saved entry missing, unreadable or
  unusable removes its own password. That happens when another slot could not
  save a change, so this slot's entry may be the older one. Its account expiry
  stays as it is: an expiry that could not be saved is lost. If even removing
  the password fails, the slot keeps it for that boot.

The account is disabled while the saved entry is applied; if a later step
fails, it stays disabled for that boot. If even disabling it fails, the slot
keeps its own entry for that boot. Either way the next boot tries again.

The old shared password, an empty password and a hash the account tools would
reject are never saved or restored: the saved entry then has no password. A
save that fails, for example for lack of space, replaces the saved entry with
an empty marker only that slot records. Until another slot saves or fails to
save, that slot keeps its own entry and saves it at its next attempt (the next
account change, boot or shutdown); every other slot that saved before starts
without a password. If `/data` cannot be written at all, not even to replace
the entry, other slots receive the older entry.

Any wipe of `/data` removes the saved entry, including the one-time conversion
to an encrypted `/data`: its snapshot of `/data` may miss the latest save, so
the entry is not carried across. Slots that saved before then start without a
password and must be provisioned again. A reinstall that keeps `/data` keeps
the password. Agent enrollment is stored under `/var/lib/wendy`, which is
mounted from `/data/wendy` for A/B updates. Verify authenticated Agent access
before and after the update.

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
