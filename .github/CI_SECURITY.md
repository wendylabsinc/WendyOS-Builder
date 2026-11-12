# Image-builder CI security

The image-builder workflow skips fork pull requests before allocating the
persistent runner, authenticating to cloud storage, or publishing driver images.
Forks still receive the GitHub-hosted publisher, script and workflow-security
checks. Maintainers must review external changes before placing them on an
organization branch for a full image build.

Actions are pinned to full upstream commit SHAs and Dependabot checks for updates.
Jobs declare their token permissions. Read-only checkouts do not persist Git
credentials. The release/promotion jobs retain authentication for intentional
Git pushes. The driver workflow receives only its two named OIDC configuration
secrets, rather than every caller secret.

`Workflow security` runs on every PR and checks both the fork-gate scenarios and
zizmor 1.32.0 high-severity, high-confidence findings. It uses the CLI because the
vendor action does not expose `--no-config` and `--no-ignores`. These flags prevent
inline exclusions from suppressing the audit. Add this check to the default-branch
ruleset after its first successful run. Lower-confidence findings require review.

```sh
python3 .github/scripts/ci_security_test.py
uvx --from zizmor==1.32.0 zizmor --offline --no-config --no-ignores --min-severity high --min-confidence high .github
```

## Required infrastructure controls

The fork gate is defense in depth. A malicious PR can modify its own workflow;
GitHub must require approval for every external contributor. This repository and
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
