# Modern (post-scarthgap) path for /var/log placement: trim
# files/fs-perms-volatile-log.txt out of the default FILESYSTEM_PERMS_TABLES
# when /var/log should be persistent. The oe-core default (whinlatter and
# later) is "files/fs-perms.txt files/fs-perms-volatile-log.txt
# files/fs-perms-volatile-tmp.txt". Removing the volatile-log entry makes
# /var/log persistent (on rootfs); leaving it makes /var/log volatile
# (tmpfs). /tmp stays volatile in both cases. Scarthgap uses the legacy
# VOLATILE_LOG_DIR — see journal-logs-scarthgap.inc.
#
# WENDYOS_PERSIST_JOURNAL_LOGS = "1" → /var/log is persistent.
# WENDYOS_PERSIST_JOURNAL_LOGS = "0" → /var/log is volatile (default).
FILESYSTEM_PERMS_TABLES:remove = "${@'files/fs-perms-volatile-log.txt' if d.getVar('WENDYOS_PERSIST_JOURNAL_LOGS') == '1' else ''}"
