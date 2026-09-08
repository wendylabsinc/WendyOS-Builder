
# Set the '/var/log' location, i.e. either on persistent storage
# of on volatile filesystem.
# The value comes from the distro default in conf/distro/wendyos.conf and can
# be overridden per machine or in local.conf. This class deliberately does not
# default it: a "?=" here does not see a weak default, so it would overwrite
# the distro value with its own. Unset already behaves as off, because the
# expression below only treats "1" as on.

# Turn the value into an override we can key off of
OVERRIDES:append = ":journal_persist-${@'on' if d.getVar('WENDYOS_PERSIST_JOURNAL_LOGS') == '1' else 'off'}"

# With modern OE-Core, whether '/var/log' is a directory or a symlink,
# it is decided by the FILESYSTEM_PERMS_TABLES during rootfs packaging.
FILESYSTEM_PERMS_TABLES = "files/fs-perms.txt"
FILESYSTEM_PERMS_TABLES:journal_persist-off += "${@'files/fs-perms-volatile-log.txt' \
    if __import__('os').path.exists(__import__('os').path.join(d.getVar('COREBASE'),'meta','files','fs-perms-volatile-log.txt')) else ''}"
FILESYSTEM_PERMS_TABLES:journal_persist-on  += "${@'files/fs-perms-persistent-log.txt' \
    if __import__('os').path.exists(__import__('os').path.join(d.getVar('COREBASE'),'meta','files','fs-perms-persistent-log.txt')) else ''}"
