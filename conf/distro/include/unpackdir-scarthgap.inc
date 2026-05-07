# Scarthgap predates the UNPACKDIR / WORKDIR split (introduced in
# styhead). Our recipes use ${UNPACKDIR} for SRC_URI-unpacked file paths
# so the same source tree builds on whinlatter (where UNPACKDIR is
# distinct: ${WORKDIR}/sources) and on scarthgap (where it is undefined
# without this shim). Alias UNPACKDIR to WORKDIR — matches the legacy
# fetcher behavior on scarthgap, so ${UNPACKDIR}/<file> resolves to the
# same directory the file is unpacked into.
UNPACKDIR = "${WORKDIR}"
