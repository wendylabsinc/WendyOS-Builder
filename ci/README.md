# CI runner image — read before editing

> **The CI build runner image is defined in `wendylabsinc/ci`.**
> Make build-environment changes there, not here.

WendyOS-Builder CI runs on the self-hosted GitHub Actions platform in
[`wendylabsinc/ci`](https://github.com/wendylabsinc/ci). On that platform the
build runner is a **container image** defined by the tenant at
`repositories/WendyOS-Builder/` (its `Dockerfile` + `install-build-deps.sh`).

The legacy Packer-built custom AMI has been removed now that the `build.yml`
cutover has landed: nothing references the `wendyos-builder` AMI (or the
`.github/runs-on.yml` image mapping) anymore. `promote.yml` moved to
`ubuntu-latest` at the same time — it's a lightweight control-plane job (tag +
release + workflow dispatch) that doesn't need a big instance. Note that
`build.yml`'s `publish-pr` job still uses RunsOn dynamic runners with the
stock image; only the custom-AMI build path is gone.

**Where changes to the "build image" go:**

| Change | Make it in |
|---|---|
| Build-environment packages / toolchain (the runner image contents) | `wendylabsinc/ci` → `repositories/WendyOS-Builder/install-build-deps.sh` |
| Runner resources, cache, isolation, labels, timeouts | `wendylabsinc/ci` → `repositories/WendyOS-Builder/configuration.yaml` |
| Launcher / host behaviour (PID limits, sysctls, cgroups, tmpdir) | `wendylabsinc/ci` (launcher + platform modules) |

Note: `scripts/install-build-deps.sh` and `scripts/upstream-repos.env` in this
repo are still used locally by `bootstrap.sh` and `scripts/docker/dockerfile`
to build the dev Docker image — they are independent of, and no longer
mirrored into, the CI runner image.

See `wendylabsinc/ci/docs/onboarding.md` and `docs/architecture.md` for the
platform model.
