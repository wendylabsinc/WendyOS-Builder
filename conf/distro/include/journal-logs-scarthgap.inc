# Scarthgap path for /var/log placement: legacy VOLATILE_LOG_DIR.
# Whinlatter and later use FILESYSTEM_PERMS_TABLES instead — see the
# sibling journal-logs-modern.inc and the gating require in wendyos.conf.
#
# WENDYOS_PERSIST_JOURNAL_LOGS = "1" → /var/log is persistent (on rootfs).
# WENDYOS_PERSIST_JOURNAL_LOGS = "0" → /var/log is volatile (tmpfs).
VOLATILE_LOG_DIR = "${@'no' if d.getVar('WENDYOS_PERSIST_JOURNAL_LOGS') == '1' else 'yes'}"
