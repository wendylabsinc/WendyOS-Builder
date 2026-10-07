/* Compile the real policy FAILED case and cooldown callbacks. Model surrounding
 * settings/manager services and time; this does not run a Wi-Fi activation. */
#include <glib-object.h>
#include <string.h>

typedef struct { const char *key_mgmt, *psk; unsigned flags; } NMSettingWirelessSecurity;
typedef struct { const char *mode; } NMSettingWireless;
typedef struct { NMSettingWireless *wifi; NMSettingWirelessSecurity *security; } NMConnection;
typedef struct { NMConnection connection; guint64 agent_version; unsigned blocked; } NMSettingsConnection;
typedef struct { int type; NMSettingsConnection *settings; } NMDevice;
typedef struct { guint32 tries; gint32 blocked_until; unsigned resets; } NMManager;
typedef struct {
    NMManager *manager;
    guint64 *agent_mgr;
    NMSettingsConnection **settings;
    void *reset_connections_retries_idle_source;
} NMPolicyPrivate;
typedef struct { NMPolicyPrivate priv; unsigned rechecks; } NMPolicy;
#define NM_POLICY_GET_PRIVATE(s) (&(s)->priv)
#define NM_DEVICE_TYPE_WIFI 2
#define NM_DEVICE_STATE_DISCONNECTED 30
#define NM_DEVICE_STATE_PREPARE 40
#define NM_DEVICE_STATE_ACTIVATED 100
#define NM_DEVICE_STATE_DEACTIVATING 110
#define NM_DEVICE_STATE_FAILED 120
#define NM_DEVICE_STATE_REASON_NO_SECRETS 7
#define NM_DEVICE_STATE_REASON_DEPENDENCY_FAILED 50
#define NM_SETTINGS_AUTOCONNECT_BLOCKED_REASON_NO_SECRETS 1
#define NM_SETTINGS_AUTOCONNECT_BLOCKED_REASON_FAILED 2
#define NM_SETTING_SECRET_FLAG_NONE 0
#define NM_SETTING_WIRELESS_MODE_INFRA "infrastructure"
#define NM_AUTOCONNECT_RETRIES_FOREVER G_MAXUINT32
#define NM_IS_SETTINGS_CONNECTION(c) ((c) != NULL)
#define nm_assert g_assert
#define nm_streq(a,b) (strcmp(a,b) == 0)
#define nm_streq0(a,b) (g_strcmp0(a,b) == 0)
#define NM_MAX MAX
#define _LOGD(...) ((void)0)
#undef g_signal_handlers_disconnect_by_func
#define g_signal_handlers_disconnect_by_func(...) ((void)0)

static NMPolicy policy;
static NMManager manager;
static NMDevice device;
static NMSettingsConnection saved, *connections[2];
static NMSettingWireless wifi;
static NMSettingWirelessSecurity security;
static guint64 agent_version;
static gint32 now, deadline;
static GSourceFunc timeout_callback;
static gpointer timeout_data;
static int nm_device_get_device_type(NMDevice *d) { return d->type; }
static NMConnection *nm_settings_connection_get_connection(NMSettingsConnection *c) { return &c->connection; }
static NMSettingWireless *nm_connection_get_setting_wireless(NMConnection *c) { return c->wifi; }
static NMSettingWirelessSecurity *nm_connection_get_setting_wireless_security(NMConnection *c) { return c->security; }
static const char *nm_setting_wireless_get_mode(NMSettingWireless *s) { return s->mode; }
static const char *nm_setting_wireless_security_get_key_mgmt(NMSettingWirelessSecurity *s) { return s->key_mgmt; }
static const char *nm_setting_wireless_security_get_psk(NMSettingWirelessSecurity *s) { return s->psk; }
static unsigned nm_setting_wireless_security_get_psk_flags(NMSettingWirelessSecurity *s) { return s->flags; }
static int nm_device_state_reason_check(int reason) { return reason; }
static guint64 nm_settings_connection_get_last_secret_agent_version_id(NMSettingsConnection *c) { return c->agent_version; }
static guint64 nm_agent_manager_get_agent_version_id(guint64 *v) { return *v; }
static void nm_settings_connection_autoconnect_blocked_reason_set(NMSettingsConnection *c, unsigned reason, gboolean value) {
    g_assert_true(value); c->blocked |= reason;
}
static void nm_manager_devcon_autoconnect_blocked_reason_set(NMManager *m, NMDevice *d, NMSettingsConnection *c, unsigned reason, gboolean value) {
    nm_settings_connection_autoconnect_blocked_reason_set(c, reason, value);
}
static guint32 nm_manager_devcon_autoconnect_retries_get(NMManager *m, NMDevice *d, NMSettingsConnection *c) { return m->tries; }
/* Manager bookkeeping is a stub: the production policy must call it and
 * schedule/rearm/reset correctly. Real 300-second recovery needs a daemon test. */
static void nm_manager_devcon_autoconnect_retries_set(NMManager *m, NMDevice *d, NMSettingsConnection *c, guint32 tries) {
    m->tries = tries; m->blocked_until = tries ? 0 : now + 300;
}
static gint32 nm_manager_devcon_autoconnect_retries_blocked_until(NMManager *m, NMDevice *d, NMSettingsConnection *c) { return m->blocked_until; }
static void nm_manager_devcon_autoconnect_retries_reset(NMManager *m, NMDevice *d, NMSettingsConnection *c) {
    m->tries = 4; m->blocked_until = 0; m->resets++;
}
static NMSettingsConnection *const *nm_settings_get_connections(NMSettingsConnection **s, void *unused) { return s; }
static gint32 nm_utils_get_monotonic_timestamp_sec(void) { return now; }
static void nm_clear_g_source_inst(void **source) { *source = NULL; }
static void *nm_g_timeout_add_seconds_source(guint seconds, GSourceFunc callback, gpointer data) {
    deadline = now + seconds; timeout_callback = callback; timeout_data = data;
    return &deadline;
}
static void nm_policy_device_recheck_auto_activate_all_schedule(NMPolicy *p) { p->rechecks++; }
#include "handlers.inc"

static void setup(void) {
    wifi = (NMSettingWireless){"infrastructure"};
    security = (NMSettingWirelessSecurity){"wpa-psk", "test-only-secret", 0};
    saved = (NMSettingsConnection){{&wifi, &security}, 1, 0};
    connections[0] = &saved; connections[1] = NULL;
    device = (NMDevice){NM_DEVICE_TYPE_WIFI, &saved};
    manager = (NMManager){4, 0, 0};
    agent_version = 1;
    policy = (NMPolicy){{&manager, &agent_version, connections, NULL}, 0};
    now = 1000; deadline = 0; timeout_callback = NULL; timeout_data = NULL;
}
static void no_secrets(void) { failure(&device, NM_DEVICE_STATE_PREPARE, NM_DEVICE_STATE_REASON_NO_SECRETS); }
static void expect_blocked(void) {
    no_secrets();
    g_assert_cmpuint(saved.blocked, ==, NM_SETTINGS_AUTOCONNECT_BLOCKED_REASON_NO_SECRETS);
    g_assert_cmpuint(manager.tries, ==, 4);
    g_assert_null(timeout_callback);
}
static void saved_key(void) {
    for (int mode = 0; mode < 2; mode++) {
        for (int version = 0; version < 2; version++) {
            setup(); wifi.mode = mode ? "infrastructure" : NULL;
            saved.agent_version = version;
            no_secrets();
            g_assert_cmpuint(saved.blocked, ==, 0);
            g_assert_cmpuint(manager.tries, ==, 3);
            g_assert_cmpstr(security.psk, ==, "test-only-secret");
            g_assert_null(timeout_callback);
        }
    }
}
static void cooldown(void) {
    setup();
    for (unsigned cycle = 1; cycle <= 3; cycle++) {
        for (unsigned tries = 4; tries > 0; tries--) {
            no_secrets();
            g_assert_cmpuint(saved.blocked, ==, 0);
            g_assert_cmpuint(manager.tries, ==, tries - 1);
        }
        g_assert_nonnull(timeout_callback);
        g_assert_cmpint(deadline, ==, now + 300);
        /* An early callback must rearm, not reset or schedule activation. */
        now = deadline - 1;
        timeout_callback(timeout_data);
        g_assert_cmpuint(manager.tries, ==, 0);
        g_assert_cmpint(deadline, ==, now + 1);
        g_assert_cmpuint(policy.rechecks, ==, cycle - 1);
        now = deadline;
        timeout_callback(timeout_data);
        g_assert_cmpuint(manager.tries, ==, 4);
        g_assert_cmpuint(manager.resets, ==, cycle);
        g_assert_cmpuint(policy.rechecks, ==, cycle);
        g_assert_cmpuint(saved.blocked, ==, 0);
        g_assert_cmpstr(security.psk, ==, "test-only-secret");
    }
}
static void missing_key(void) {
    setup(); security.psk = NULL; expect_blocked();
    setup(); security.psk = ""; expect_blocked();
    setup(); saved.connection.security = NULL; expect_blocked();
}
static void secret_flags(void) {
    for (unsigned flags = 1; flags < 8; flags++) {
        setup(); security.flags = flags; expect_blocked();
    }
}
static void other_security(void) {
    const char *types[] = {NULL, "none", "sae", "wpa-eap", "ieee8021x", "owe"};
    for (unsigned i = 0; i < G_N_ELEMENTS(types); i++) {
        setup(); security.key_mgmt = types[i]; expect_blocked();
    }
}
static void other_modes(void) {
    const char *modes[] = {"ap", "adhoc", "mesh"};
    for (unsigned i = 0; i < G_N_ELEMENTS(modes); i++) {
        setup(); wifi.mode = modes[i]; expect_blocked();
    }
    setup(); saved.connection.wifi = NULL; expect_blocked();
}
static void other_device(void) { setup(); device.type = 1; expect_blocked(); }
static void activation_state(void) {
    const int states[] = {NM_DEVICE_STATE_DISCONNECTED, NM_DEVICE_STATE_DEACTIVATING, NM_DEVICE_STATE_FAILED};
    for (unsigned i = 0; i < G_N_ELEMENTS(states); i++) {
        setup(); failure(&device, states[i], NM_DEVICE_STATE_REASON_NO_SECRETS);
        g_assert_cmpuint(manager.tries, ==, 4); g_assert_cmpuint(saved.blocked, ==, 0);
    }
    setup(); device.settings = NULL; no_secrets();
    g_assert_cmpuint(manager.tries, ==, 4);
}
static void agent_registration(void) {
    setup(); security.psk = NULL; agent_version = 2; no_secrets();
    g_assert_cmpuint(saved.blocked, ==, 0); g_assert_cmpuint(manager.tries, ==, 3);
    setup(); security.psk = NULL; saved.agent_version = 0; agent_version = 2; expect_blocked();
}
static void other_failures(void) {
    setup(); failure(&device, NM_DEVICE_STATE_PREPARE, NM_DEVICE_STATE_REASON_DEPENDENCY_FAILED);
    g_assert_cmpuint(saved.blocked, ==, NM_SETTINGS_AUTOCONNECT_BLOCKED_REASON_FAILED);
    g_assert_cmpuint(manager.tries, ==, 4);
    setup(); failure(&device, NM_DEVICE_STATE_PREPARE, 11); /* ordinary timeout */
    g_assert_cmpuint(saved.blocked, ==, 0); g_assert_cmpuint(manager.tries, ==, 3);
}
static void retry_limits(void) {
    const guint32 limits[] = {0, NM_AUTOCONNECT_RETRIES_FOREVER};
    for (unsigned i = 0; i < G_N_ELEMENTS(limits); i++) {
        setup(); manager.tries = limits[i];
        no_secrets();
        g_assert_cmpuint(manager.tries, ==, limits[i]); g_assert_null(timeout_callback);
    }
}
static void existing_blocks(void) {
    setup(); saved.blocked = 8; /* an independent user-request block */
    no_secrets();
    g_assert_cmpuint(saved.blocked & 8, ==, 8);
    manager.blocked_until = now; reset_connections_retries(&policy);
    g_assert_cmpuint(saved.blocked & 8, ==, 8);
}
int main(int argc, char **argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/recovery/saved-key", saved_key);
    g_test_add_func("/recovery/cooldown", cooldown);
    g_test_add_func("/control/missing-key", missing_key);
    g_test_add_func("/control/secret-flags", secret_flags);
    g_test_add_func("/control/security", other_security);
    g_test_add_func("/control/modes", other_modes);
    g_test_add_func("/control/device", other_device);
    g_test_add_func("/control/activation-state", activation_state);
    g_test_add_func("/control/agent-registration", agent_registration);
    g_test_add_func("/control/other-failures", other_failures);
    g_test_add_func("/control/retry-limits", retry_limits);
    g_test_add_func("/control/existing-blocks", existing_blocks);
    return g_test_run();
}
