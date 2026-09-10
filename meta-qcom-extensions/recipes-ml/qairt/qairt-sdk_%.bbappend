# Upstream recommends a skel package for every Hexagon version. The SoC fixes which one
# is usable and the packagegroup names it, so drop the skels by shape: a named list would
# either admit a version added later or remove the one another board needs.
python () {
    import re
    pn = d.getVar('PN')
    skel = re.compile(r'^%s-hexagon-v\d+$' % re.escape(pn))
    var = 'RRECOMMENDS:' + pn
    deps = bb.utils.explode_dep_versions2(d.getVar(var) or '')
    for pkg in list(deps):
        if skel.match(pkg):
            del deps[pkg]
    d.setVar(var, bb.utils.join_deps(deps, commasep=False))
}
