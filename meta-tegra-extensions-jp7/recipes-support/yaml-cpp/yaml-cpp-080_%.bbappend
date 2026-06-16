# Build yaml-cpp-080 as a SHARED library for blacksail/JP7.2.
#
# DeepStream 8.0's prebuilt libs dynamically link libyaml-cpp.so.0.8, but the
# meta-tegra-community yaml-cpp-080 recipe builds STATIC
# (-DYAML_BUILD_SHARED_LIBS=OFF) — its main runtime package is empty and it
# ships no .so, so DS8 has no provider for libyaml-cpp.so.0.8 (do_rootfs:
# "nothing provides ..."). Flip it to shared so it ships libyaml-cpp.so.0.8
# (packaged, via OE's debian renaming, as 'libyaml-cpp').
#
# This bbappend lives in meta-tegra-extensions-jp7, which is only in the
# blacksail/JP7 bblayers, so it is inherently scoped to that tree (scarthgap
# uses yaml-cpp-070 for DeepStream 7.1 and never sees this).
EXTRA_OECMAKE = "-DYAML_CPP_BUILD_TESTS=OFF -DYAML_BUILD_SHARED_LIBS=ON -DYAML_CPP_BUILD_TOOLS=OFF"
