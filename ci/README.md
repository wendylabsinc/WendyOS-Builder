# CI runner image — read before editing

> **The CI build runner image is being migrated to `wendylabsinc/ci`.**
> Make build-environment changes there, not here.

WendyOS-Builder CI is moving from the AWS/RunsOn model (the custom AMI defined in
this directory) to the self-hosted GitHub Actions platform in
[`wendylabsinc/ci`](https://github.com/wendylabsinc/ci). On that platform the
build runner is a **container image** defined by the tenant at
`repositories/WendyOS-Builder/` (its `Dockerfile` + `install-build-deps.sh`).

**Where changes to the "build image" go:**

| Change | Make it in |
|---|---|
| Build-environment packages / toolchain (the runner image contents) | `wendylabsinc/ci` → `repositories/WendyOS-Builder/install-build-deps.sh` |
| Runner resources, cache, isolation, labels, timeouts | `wendylabsinc/ci` → `repositories/WendyOS-Builder/configuration.yaml` |
| Launcher / host behaviour (PID limits, sysctls, cgroups, tmpdir) | `wendylabsinc/ci` (launcher + platform modules) |

`ci/packer/` and `.github/workflows/build-ami.yml` (the AWS AMI path) remain
**only** until the `build.yml` cutover lands, then they are removed. Until then,
if you must touch a build dependency for the legacy AMI, mirror the same change
into the `wendylabsinc/ci` copy so the two don't diverge.

See `wendylabsinc/ci/docs/onboarding.md` and `docs/architecture.md` for the
platform model.
