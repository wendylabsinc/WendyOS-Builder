# Qualcomm NPU as a systemd-sysext add-on

The Dragonwing IQ-8275's Hexagon NPU is reached through FastRPC: an application
links `libcdsprpc.so`, the kernel's `fastrpc` driver asks the compute DSP to
create a dynamic protection domain, and the Qualcomm AI Runtime (QAIRT/QNN)
libraries run the model inside it.

That stack splits cleanly in two, and the split is not a matter of taste — it
follows the DSP's own trust model.

## Why the seam is where it is

The signed DSP firmware (`cdsp0.mbn`) embeds the SHA-256 digest of every ELF
segment of each Hexagon binary it is willing to admit. When the kernel asks for a
dynamic PD, the DSP hashes the `fastrpc_shell_unsigned_3` it is handed and
refuses it outright if the digests are not in its table. The failure surfaces as
`AEE_ECONNREFUSED` from `fastrpc_test`, with nothing in `dmesg`.

So the **shell is firmware-locked** and has to ship with the firmware. The QNN
skels are not: they are loaded by the shell into an already-authorised unsigned
PD, so they carry no firmware signature and are free to be versioned on their
own. Hence:

| Component | Package | Where |
| --- | --- | --- |
| FastRPC driver | `kernel-module-fastrpc` | base rootfs |
| FastRPC daemons + `libcdsprpc.so` | `fastrpc` | base rootfs |
| DSP firmware (`cdsp0`/`adsp`/`gpdsp0`.mbn) | `linux-firmware-qcom-qcs8300-*` | base rootfs |
| Hexagon shell + DSP-side libc | `hexagon-dsp-binaries-qcom-iq8275-evk-*` | base rootfs |
| DT-model → DSP path map | `hexagon-dsp-binaries-qualcomm-iq8275-evk-config` | base rootfs |
| QAIRT/QNN host runtime + tools | `qairt-sdk` | **NPU sysext** |
| QNN HTP v75 DSP skels | `qairt-sdk-hexagon-v75` | **NPU sysext** |
| `dsp_check`, `fastrpc_test` | `fastrpc-tests` | **NPU sysext** |

Firmware also has to be in the rootfs for a second, independent reason:
remoteproc loads it about 11 s into boot, well before `wendyos-sysext-apply`
merges anything.

### Verifying a firmware bump

`linux-firmware` and `hexagon-dsp-binaries` are released in lockstep, and
upstream encodes the lock as a version-pinned `RDEPENDS`:

    hexagon-dsp-binaries-qcom-qcs8300-ride-cdsp
        RDEPENDS = "linux-firmware-qcom-qcs8300-compute (= 1:${PV})"

meta-qcom then reaches those packages through
`MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS`, so a mismatch does not fail the build —
it silently drops the entire DSP userspace and the board comes up with no
offload at all. `packagegroup-wendyos-qcom` therefore names them as `RDEPENDS`,
so the next skew is a build failure instead.

The dsp-binaries tree ships its own offline checker. Point it at an unpacked
`linux-firmware` and it verifies every Hexagon binary against the firmware's
digest table:

    # RUN ON HOST
    python3 scripts/checkfw.py <path-to-linux-firmware>

Silence means every binary is authorised.

### Avoiding the firmware bump altogether

Bumping `SRCREV_OECORE` to reach linux-firmware 20260810 is a world rebuild — 164
oe-core commits, every board revalidated — for a fix only this board needs. There is
a cheaper route, because `hexagon-dsp-binaries` ships DSP userspace for *seven*
firmware builds per DSP and `config.txt` merely selects one:

    qcs8300/Qualcomm/QCS8300-RIDE/cdsp-DSP.AT.1.0.1-00201-LEMANS-2   <- our 20260622
    qcs8300/Qualcomm/QCS8300-RIDE/cdsp-DSP.AT.1.0.1-00204-LEMANS-1   <- upstream's pick

So instead of moving the firmware forward, retarget the userspace backward to the
build the firmware we already ship authorises. Verified offline: all 15 Hexagon ELFs
in the `00201-LEMANS-2` set — `fastrpc_shell_unsigned_3` included — match segment
digests in our own `cdsp0.mbn`, and `checkfw.py` goes silent for qcs8300.

Two things have to move together in a `hexagon-dsp-binaries` bbappend: `config.txt`,
and the version-pinned `RDEPENDS` on `linux-firmware-qcom-qcs8300-*`, which is
generated from the recipe's own `PV` and stays unsatisfiable otherwise. Swapping only
the three `.mbn` blobs does *not* avoid that second step — a package's EVR does not
change when its file contents do.

The cost is pinning to the older firmware/userspace pair, forgoing whatever changed
between `00201` and `00204`. Not yet confirmed on hardware: the on-device proof was
run with the `00204` pair.

## Building

The add-on is gated on `WENDYOS_QCOM_NPU` (default `1` for this board) and is
built and deployed beside the image, never installed into it:

    # RUN ON HOST
    make build MACHINE=iq-8275-evk-wendyos

    build/tmp/deploy/images/iq-8275-evk-wendyos/wendyos-qcom-npu.raw

Set `WENDYOS_QCOM_NPU = "0"` to skip it; the only cost is the QAIRT SDK's 2.3 GB
download, since the add-on adds nothing to the rootfs or the OTA payload.

`wendyos-qcom-npu-sysext.bb` is an image recipe, so the payload is produced by
the same `qairt-sdk` and `fastrpc` recipes the rest of the build uses — nothing
is rebuilt or reimplemented. Its rootfs is then pruned down to exactly the files
its payload packages record in pkgdata, because a merged add-on's `/usr` is
stacked over the host's and any `glibc` or `base-files` left behind would shadow
the host's own copy.

## Installing on a device

The store is `/data/extensions/enabled/`, with one bucket per kernel plus an
`any` bucket for add-ons that do not depend on a kernel. This one is userspace
only — it reaches the kernel solely through the FastRPC character device, and its
`extension-release` deliberately carries no `WENDYOS_KERNEL` field — so it goes
in `any` and survives a kernel bump.

    # RUN ON HOST
    scp wendyos-qcom-npu.raw wendy@<device>:/tmp/

    # RUN ON DRAGONWING
    sudo install -D -m 0644 /tmp/wendyos-qcom-npu.raw \
        /data/extensions/enabled/any/wendyos-qcom-npu.raw
    sudo /usr/sbin/wendyos-sysext-apply.sh

`wendyos-sysext-apply.service` re-runs that at every boot, so the add-on comes
back after a reboot and after an A/B swap — `/data` is shared between slots. To
remove it, delete the `.raw` and re-run the script; the merge is dropped.

The merge is `--mutable=ephemeral`, so nothing it writes persists, and it is
restricted to `/usr`.

## Verifying inference

    # RUN ON DRAGONWING
    systemd-sysext status
    dsp_check                       # expect "FastRPC Support: Yes"
    fastrpc_test -d 3 -a v75        # expect "Sum = 499500", "Max = 999"
    ls /usr/lib/libQnn*.so          # only present while merged

`-d 3` is the compute DSP; `-a v75` matches the SoC's Hexagon version. Domain 0
is the ADSP and domain 4 the GPDSP, both of which work the same way.

The QNN skels resolve through a symlink that lives in the base image:
`/usr/share/qcom/qcs8300/Qualcomm/IQ8275-EVK/dsp/cdsp` points at
`../../QCS8300-RIDE/dsp/cdsp`, which after the merge is an overlay of the base
image's DSP runtime and the add-on's skels. `libcdsprpc.so` resolves that path
lazily, in the application process, on first use — so a merge takes effect
without restarting `cdsprpcd`.

## Compatibility metadata

`/usr/lib/extension-release.d/extension-release.wendyos-qcom-npu` carries what
the add-on was built against. systemd reads `ID`, `SYSEXT_LEVEL` and
`ARCHITECTURE` and ignores the rest:

    ID=wendyos
    SYSEXT_LEVEL=1
    ARCHITECTURE=arm64
    EXTENSION_RELOAD_MANAGER=1
    WENDYOS_EXTENSION=qcom-npu
    WENDYOS_EXTENSION_VERSION=1.0
    WENDYOS_EXTENSION_BUILT_FOR_OS=0.19.1
    WENDYOS_EXTENSION_SOC=qcs8300
    WENDYOS_EXTENSION_DSP_ARCH=v75
    WENDYOS_EXTENSION_QAIRT_VERSION=2.47.0.260601

`SYSEXT_LEVEL` rather than `VERSION_ID`: systemd compares it when host and add-on
both declare one, and matching on `VERSION_ID` would unmerge every add-on on each
OS patch release. Bump it only on a breaking change to what an add-on may rely
on.

Nothing verifies these fields, or the image's integrity, before merging yet.

## Building an add-on outside Yocto

`scripts/pack-sysext.sh` packs a payload into the same layout with the same
metadata, so a developer building against a devkit produces an interchangeable
image:

    # RUN ON HOST
    scripts/pack-sysext.sh --devkit <devkit> --driver <manifest-dir> \
        --payload <dir-with-usr-tree> --out my-npu.raw

`--payload` takes a prebuilt `/usr` tree as it stands; `--modules` stages kernel
modules into the layout `depmod` expects. At least one is required and both may
be given. Only a pack that carries modules gets a `WENDYOS_KERNEL` field.

The kernel devkit that `--devkit` points at is the module-building contract; a
userspace add-on needs only its `os_id`, `sysext_level` and `arch`. A dedicated
userspace devkit — the `wendy devkit download --type npu` model — does not exist
yet.
