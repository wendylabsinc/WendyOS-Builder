# The Python bindings are unused and would bring python3 into every image.
PACKAGECONFIG:remove:class-target = "python3"
# The manual pages are built with pod2man; only python3 brought perl-native in.
DEPENDS:append:class-target = " perl-native"
