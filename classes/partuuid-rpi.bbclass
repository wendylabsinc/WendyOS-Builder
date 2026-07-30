
# partuuid.bbclass - Derive stable UUIDs for partition references
#
# Exposes:
#   WENDYOS_BOOT_PARTUUID
#   WENDYOS_ROOT_PARTUUID
#   WENDYOS_CONFIG_PARTUUID
#
#   do_generate_partuuids: writes the chosen values to:
#     - ${WORKDIR}/partuuids.conf
#     - ${DEPLOY_DIR_IMAGE}/partuuids-${IMAGE_BASENAME}.conf
#
# The UUIDs are deterministic (UUIDv5 of PARTUUID_SEED), not random, because they
# are task-signature inputs: an earlier revision cached UUIDv4s under ${TOPDIR},
# a fresh workspace every CI run, so the base-files/cmdline/image chain never hit
# sstate. They only need to be unique per disk, not per build - every device
# flashing a given image already shares them.
#
# The seed includes MACHINE so the nvme and sd variants of the same device get
# distinct UUIDs: both disks can be attached to one board at the same time, and
# identical PARTUUIDs across them would make root=PARTUUID=... ambiguous.
PARTUUID_SEED ?= "${DISTRO}/${MACHINE}"

# Fixed namespace for the UUIDv5 derivation. Never change it: new values would
# re-key every partuuid-dependent task signature and, worse, orphan the
# fstab/cmdline references of already-flashed disks on the next OTA.
PARTUUID_NAMESPACE = "b8f4a3d2-6e75-4d11-9c3a-2f08154cf05e"

# Name of the audit file dropped next to images:
PARTUUIDS_DEPLOY_NAME ?= "partuuids-${IMAGE_BASENAME}.conf"

python __anonymous() {
    import uuid

    ns = uuid.UUID(d.getVar('PARTUUID_NAMESPACE'))
    seed = d.getVar('PARTUUID_SEED')

    # export the variables to datastore
    d.setVar('WENDYOS_BOOT_PARTUUID', str(uuid.uuid5(ns, seed + '/boot')))
    d.setVar('WENDYOS_ROOT_PARTUUID', str(uuid.uuid5(ns, seed + '/root')))
    d.setVar('WENDYOS_CONFIG_PARTUUID', str(uuid.uuid5(ns, seed + '/config')))

    # make the variables available to WIC as well
    existing = (d.getVar('WICVARS') or '').split()
    for v in ['WENDYOS_BOOT_PARTUUID', 'WENDYOS_ROOT_PARTUUID',
              'WENDYOS_CONFIG_PARTUUID', 'WENDYOS_CONFIG_PART_SIZE_MB']:
        if v not in existing:
            existing.append(v)
    d.setVar('WICVARS', ' '.join(existing))
}

python do_generate_partuuids() {
    import os

    boot_uuid = d.getVar('WENDYOS_BOOT_PARTUUID')
    root_uuid = d.getVar('WENDYOS_ROOT_PARTUUID')
    config_uuid = d.getVar('WENDYOS_CONFIG_PARTUUID')

    # helper file to be used if a shell task or external script wants to source the
    # values instead of relying on BitBake variable expansion
    work_conf = os.path.join(d.getVar('WORKDIR'), 'partuuids.conf')
    with open(work_conf, 'w') as f:
        f.write(f"WENDYOS_BOOT_PARTUUID={boot_uuid}\n")
        f.write(f"WENDYOS_ROOT_PARTUUID={root_uuid}\n")
        f.write(f"WENDYOS_CONFIG_PARTUUID={config_uuid}\n")

    # audit file to be used if post-build tooling/CI needs to read
    # the UUIDs from ${DEPLOY_DIR_IMAGE} without parsing BitBake logs
    deploy_dir = d.getVar('DEPLOY_DIR_IMAGE')
    deploy_name = d.getVar('PARTUUIDS_DEPLOY_NAME')
    if deploy_dir and deploy_name:
        os.makedirs(deploy_dir, exist_ok=True)
        with open(os.path.join(deploy_dir, deploy_name), 'w') as f:
            f.write(f"WENDYOS_BOOT_PARTUUID={boot_uuid}\n")
            f.write(f"WENDYOS_ROOT_PARTUUID={root_uuid}\n")
            f.write(f"WENDYOS_CONFIG_PARTUUID={config_uuid}\n")

    bb.note(f"partuuids: using boot={boot_uuid} root={root_uuid} config={config_uuid}")
}

addtask generate_partuuids before do_configure after do_patch

# re-run the task if these knobs change
do_generate_partuuids[vardeps] += "WENDYOS_BOOT_PARTUUID WENDYOS_ROOT_PARTUUID WENDYOS_CONFIG_PARTUUID PARTUUIDS_DEPLOY_NAME"
