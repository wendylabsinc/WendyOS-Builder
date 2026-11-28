/* SPDX-License-Identifier: MIT */
#define _POSIX_C_SOURCE 200809L
#include <security/pam_modules.h>
#include <security/pam_ext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <syslog.h>

#ifndef NOTICE_FILE
#define NOTICE_FILE "/usr/share/wendyos-access-notice/usg-notice"
#endif
#define CONSENT_KEY "wendyos-access-notice-consent"

static void cleanup(pam_handle_t *pamh, void *data, int status)
{
    (void)pamh;
    (void)status;
    free(data);
}

/* sshd lists every completed method, one per line, in the PAM environment. */
static int ssh_key_verified(pam_handle_t *pamh)
{
    const char *info = pam_getenv(pamh, "SSH_AUTH_INFO_0");

    while (info != NULL && *info != '\0') {
        if (strncmp(info, "publickey ", 10) == 0)
            return 1;
        info = strchr(info, '\n');
        if (info != NULL)
            info++;
    }
    return 0;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                  int argc, const char **argv)
{
    char notice[8192], *answer = NULL, *accepted_user = NULL;
    const char *user = NULL;
    const void *service = NULL;
    struct stat st;
    size_t size;
    int result;
    FILE *file;
    (void)argv;

    /* A second attempt must never inherit acceptance from an earlier one. */
    result = pam_set_data(pamh, CONSENT_KEY, NULL, NULL);
    if (result != PAM_SUCCESS)
        return result;
    if (argc != 0 || (flags & PAM_SILENT))
        return PAM_AUTH_ERR;
    /* The SSH stack has no other authenticator: consent alone must never
     * log a user in, whatever AuthenticationMethods a Match block leaves. */
    if (pam_get_item(pamh, PAM_SERVICE, &service) != PAM_SUCCESS || service == NULL)
        return PAM_AUTH_ERR;
    if (strcmp(service, "sshd") == 0 && !ssh_key_verified(pamh)) {
        pam_syslog(pamh, LOG_NOTICE, "USG access notice refused: no verified SSH key");
        return PAM_AUTH_ERR;
    }
    file = fopen(NOTICE_FILE, "r");
    if (file == NULL)
        return PAM_AUTH_ERR;
    if (fstat(fileno(file), &st) != 0 || !S_ISREG(st.st_mode) ||
        st.st_uid != 0 || (st.st_mode & 022) != 0) {
        fclose(file);
        return PAM_AUTH_ERR;
    }
    size = fread(notice, 1, sizeof(notice) - 1, file);
    if (ferror(file) || size == 0 || !feof(file) ||
        memchr(notice, '\0', size) != NULL) {
        fclose(file);
        return PAM_AUTH_ERR;
    }
    fclose(file);
    notice[size] = '\0';

    result = pam_get_user(pamh, &user, NULL);
    if (result != PAM_SUCCESS || user == NULL || user[0] == '\0')
        return PAM_AUTH_ERR;
    accepted_user = strdup(user);
    if (accepted_user == NULL)
        return PAM_BUF_ERR;
    result = pam_prompt(pamh, PAM_PROMPT_ECHO_ON, &answer,
                        "%s\nType ACCEPT to acknowledge these conditions: ", notice);
    if (result != PAM_SUCCESS || answer == NULL || strcmp(answer, "ACCEPT") != 0) {
        free(answer);
        free(accepted_user);
        pam_syslog(pamh, LOG_NOTICE, "USG access notice not acknowledged");
        return PAM_AUTH_ERR;
    }
    free(answer);
    result = pam_set_data(pamh, CONSENT_KEY, accepted_user, cleanup);
    if (result != PAM_SUCCESS) {
        free(accepted_user);
        return result;
    }
    pam_syslog(pamh, LOG_NOTICE, "USG access notice acknowledged");
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags,
                               int argc, const char **argv)
{
    const void *accepted_user = NULL;
    const char *user = NULL;
    (void)flags;
    (void)argv;
    /* Reject public-key-only or login -f paths that skipped authenticate(). */
    if (argc != 0 || pam_get_data(pamh, CONSENT_KEY, &accepted_user) != PAM_SUCCESS ||
        accepted_user == NULL || pam_get_user(pamh, &user, NULL) != PAM_SUCCESS ||
        user == NULL || strcmp(accepted_user, user) != 0)
        return PAM_PERM_DENIED;
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags,
                             int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
