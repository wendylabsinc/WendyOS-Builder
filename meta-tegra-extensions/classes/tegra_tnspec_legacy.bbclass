# Units keep the TnSpec machine name they first booted with, so every BUP signs one spec set per name.
# Inherited by the capsule recipe and the image, so the capsule and the bundle's script agree.
WENDYOS_TNSPEC_LEGACY_MACHINES ??= ""

# Upstream wrote one MACHINE=${TNSPEC_MACHINE} line per spec; repeat each for every legacy name.
tegraflash_generate_bupgen_script:append:tegra234() {
    if [ -n "${WENDYOS_TNSPEC_LEGACY_MACHINES}" ]; then
        grep "^MACHINE=${TNSPEC_MACHINE} " $outfile > $outfile.specs || \
            bbfatal "$outfile has no MACHINE=${TNSPEC_MACHINE} line to repeat for the legacy names"
        for machine__ in ${WENDYOS_TNSPEC_LEGACY_MACHINES}; do
            sed "s/^MACHINE=${TNSPEC_MACHINE} /MACHINE=$machine__ /" $outfile.specs >> $outfile
        done
        rm -f $outfile.specs
    fi
}
