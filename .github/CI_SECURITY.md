# Image-builder CI security

The image-builder workflow runs only for pushes, manual dispatches and
same-repository pull requests. Every other event, every fork pull request and
every Dependabot update stops at `detect-changes`, before a job allocates the
persistent runner, authenticates to cloud storage, or publishes driver images.
The image, publish and driver jobs all need `detect-changes`, so that one
condition gates them all, and a trigger added later stays out until it is
listed there. Pushes are trusted because the workflow takes them only from
`main` and from release tags.

Forks still receive the GitHub-hosted publisher, script and workflow-security
checks. `Required CI` fails on a fork pull request and says why, so a fork can
not merge without an image build. Maintainers must review external changes
before placing them on an organization branch for a full image build.

Actions are pinned to full upstream commit SHAs, each named by its exact
release. Dependabot proposes version updates once a month, for releases at
least 14 days old: minor and patch releases in one grouped pull request, each
major release in its own. Security updates are not delayed or grouped.

An update is third-party code, so it does not build on the image builder by
itself: `Required CI` fails until a maintainer acts on the pull request. Read
the diff first, then push a commit to the Dependabot branch (an empty one is
enough). The gate can not tell that push from any other maintainer action:
`Update branch` and reopening the pull request also start the build, so do
neither before reading the diff. After a maintainer's commit Dependabot stops
rebasing the pull request, and it must be kept up to date by hand.

Jobs that can publish restore no shared cache, so each one downloads the Go
modules and compiles the publisher itself. Jobs declare their token
permissions. Read-only checkouts do not persist Git credentials. The
release/promotion jobs retain authentication for intentional Git pushes. The
driver workflow receives only its two named OIDC configuration secrets, rather
than every caller secret.

`Workflow security` runs on every PR. `ci_security_test.py` applies the rules
above to every workflow and job instead of to named ones: a job with its own
runner, a write token, secrets or a called workflow must sit behind the gate.
It checks the patterns it knows, and is not a proof. zizmor then reports
findings of medium severity and confidence or higher, in its default persona;
its stricter personas report more, and need review by hand. It uses the CLI
because the vendor action does not expose `--no-config` and `--no-ignores`.
These flags prevent inline exclusions from suppressing the audit. Both tools are
installed from `.github/scripts/requirements.txt`, pinned by hash. The AI
security review installs its SDK the same way, from `.github/security-review/`.
Add this check to the default-branch ruleset after its first successful run.

Two findings stay below the threshold on purpose: the release and promotion
checkouts keep their credentials because those jobs push tags. Cache poisoning
is reported below it too, so the test holds the no-cache rule.

```sh
python3 -m venv /tmp/workflow-audit
/tmp/workflow-audit/bin/pip install --require-hashes -r .github/scripts/requirements.txt
/tmp/workflow-audit/bin/python .github/scripts/ci_security_test.py
/tmp/workflow-audit/bin/zizmor --offline --no-config --no-ignores --min-severity medium --min-confidence medium .github
```

## Required infrastructure controls

The gate and its test are defense in depth. A pull request runs its own copy of
the workflow and of the test, so a malicious one can remove both; GitHub must
require approval for every external contributor. This repository and
all other non-archived public organization repositories were verified to use that
policy on 2026-11-12. Approval must cover changes to workflows and executed scripts.

Same-repository PRs still execute on the image builder and share persistent Yocto
caches with releases. A stolen collaborator account remains a risk. Runner-group
restrictions must bind access to trusted workflow refs, and unreviewed builds need
isolation from release machines and writable release caches. Cloud OIDC trust must
also distinguish PR image storage from production release storage.

The investigation could not read organization runner groups or audit logs because
the available CLI token lacked organization permissions. These controls and
cloud-side IAM need verification before treating the release infrastructure as
fully hardened. A clean workflow scan does not establish runner or account safety.
