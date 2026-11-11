/* SPDX-License-Identifier: MIT */
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct answers { const char *notice; const char *password; };

static int conversation(int count, const struct pam_message **messages,
                        struct pam_response **responses, void *data)
{
    struct answers *answers = data;
    struct pam_response *out = calloc((size_t)count, sizeof(*out));
    if (!out)
        return PAM_BUF_ERR;
    for (int i = 0; i < count; i++) {
        if (messages[i]->msg_style == PAM_PROMPT_ECHO_ON ||
            messages[i]->msg_style == PAM_PROMPT_ECHO_OFF) {
            const char *answer = strstr(messages[i]->msg, "Type ACCEPT") ?
                answers->notice : answers->password;
            if (strcmp(answer, "CANCEL") == 0) {
                for (int j = 0; j < i; j++) free(out[j].resp);
                free(out);
                return PAM_CONV_ERR;
            }
            out[i].resp = strdup(answer);
        }
    }
    *responses = out;
    return PAM_SUCCESS;
}

int main(int argc, char **argv)
{
    pam_handle_t *pamh = NULL;
    if (argc != 5)
        return 2;
    struct answers answers = {argv[2], argv[3]};
    struct pam_conv conv = {conversation, &answers};
    int result = pam_start(argv[1], "noticeuser", &conv, &pamh);
    if (result != PAM_SUCCESS)
        return 3;
    if (strcmp(argv[4], "account-only") != 0)
        result = pam_authenticate(pamh, strcmp(argv[4], "silent") == 0 ? PAM_SILENT : 0);
    if (result == PAM_SUCCESS && strcmp(argv[4], "repeat-refuse") == 0) {
        answers.notice = "NO";
        (void)pam_authenticate(pamh, 0);
    }
    if (result == PAM_SUCCESS && strcmp(argv[4], "change-user") == 0)
        (void)pam_set_item(pamh, PAM_USER, "root");
    if (result == PAM_SUCCESS)
        result = pam_acct_mgmt(pamh, 0);
    printf("PAM result: %d\n", result);
    pam_end(pamh, result);
    return result == PAM_SUCCESS ? 0 : 1;
}
