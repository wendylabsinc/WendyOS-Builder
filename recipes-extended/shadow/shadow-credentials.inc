# passwd must run common-password; the non-PAM implementation bypasses it.
# Do not change native useradd used when constructing the root filesystem.
PACKAGECONFIG:append:class-target = " pam"
