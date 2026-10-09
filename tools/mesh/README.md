# Local agent images

Use `package-local-agent.py` to include an unpublished Linux ARM64 Wendy agent
in a local image build. Both the WendyOS and Builder checkouts must be clean
and committed. Choose a new output directory outside both repositories:

```sh
python3 tools/mesh/package-local-agent.py \
  --source ../WendyOS \
  --output /tmp/wendy-local-agent \
  --version 2026.10.09-mesh-dev
```

Add `/tmp/wendy-local-agent/layer` to `BBLAYERS` in the image build's
`conf/bblayers.conf` (use the path as seen inside Docker when building there).
The layer supplies the local archive and masks the agent's automatic updater
timer. Remove the layer to return to the normal release selection.

`BUILD-PROVENANCE.json` records the source and Builder commits, hashes of the
committed Builder inputs, the compiler read from the finished binary, and the
binary/archive checksums. The build ignores an ambient Go workspace and
persistent Go flags; it does not modify module dependencies. `--go` can select
a particular Go executable. Go may select a newer toolchain required by the
source checkout; the manifest records the compiler actually used.

Packaging does not validate the resulting image or hardware behavior. The
manifest leaves those checks pending. Regression tests run in Scripts CI and
can also be run locally:

```sh
python3 -m unittest scripts/package_local_agent_test.py
```
