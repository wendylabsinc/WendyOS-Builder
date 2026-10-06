/* Compile the real callbacks; model only NM's surrounding services. */
#include <glib-object.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

typedef int NMSupplicantInterfaceState;
typedef int NMSupplicantInterface;
typedef struct { const char *key_mgmt, *psk; unsigned flags; } NMSettingWirelessSecurity;
typedef struct { NMSettingWirelessSecurity *security; } NMConnection;
typedef struct { NMConnection connection; guint64 timestamp; gboolean has_timestamp; } NMSettingsConnection;
typedef GObject NMActRequest;
typedef struct { NMSettingsConnection settings; NMConnection applied; int reason; } Request;
typedef struct { int mode; guint sup_timeout_id; gboolean ssid_found; } NMDeviceWifiPrivate;
typedef struct {
    NMDeviceWifiPrivate priv;
    NMActRequest *req;
    int state, reason;
    unsigned cleanup, clear, secrets, auth;
    gboolean enterprise, auth_available, new_secrets;
} NMDeviceWifi;
typedef NMDeviceWifi NMDevice;
#define NM_DEVICE_WIFI_GET_PRIVATE(s) (&(s)->priv)
#define NM_DEVICE(s) (s)
#define NM_DEVICE_WIFI(s) ((NMDeviceWifi *)(s))
#define NM_ACTIVE_CONNECTION(r) (r)
#define NM_ACTIVATION_REASON_AUTOCONNECT 1
#define NM_SUPPLICANT_INTERFACE_STATE_4WAY_HANDSHAKE 4
#define NM_SUPPLICANT_INTERFACE_STATE_DISCONNECTED 5
#define NM_DEVICE_STATE_CONFIG 10
#define NM_DEVICE_STATE_NEED_AUTH 11
#define NM_DEVICE_STATE_FAILED 12
#define NM_DEVICE_STATE_ACTIVATED 13
#define NM_DEVICE_STATE_REASON_SUPPLICANT_DISCONNECT 20
#define NM_DEVICE_STATE_REASON_SUPPLICANT_TIMEOUT 21
#define NM_DEVICE_STATE_REASON_NO_SECRETS 22
#define NM_DEVICE_STATE_REASON_SSID_NOT_FOUND 23
#define _NM_802_11_MODE_INFRA 1
#define _NM_802_11_MODE_ADHOC 2
#define _NM_802_11_MODE_MESH 3
#define _NM_802_11_MODE_AP 4
#define NM_SETTING_SECRET_FLAG_NONE 0
#define NM_SETTING_WIRELESS_SECURITY_SETTING_NAME "wireless-security"
#define NM_SECRET_AGENT_GET_SECRETS_FLAG_ALLOW_INTERACTION 1
#define NM_SECRET_AGENT_GET_SECRETS_FLAG_REQUEST_NEW 2
#define NM_IN_SET(x,a,b,c) ((x)==(a)||(x)==(b)||(x)==(c))
#define LOGD_DEVICE 1
#define LOGD_WIFI 2
#define _LOGI log_message
#define _LOGW log_message

static NMDeviceWifi d;
static Request r;
static NMSettingWirelessSecurity stored, applied;
static GString *messages;
static void log_message(int domain, const char *format, ...) {
    va_list args;
    va_start(args, format);
    g_string_append_vprintf(messages, format, args);
    g_string_append_c(messages, '\n');
    va_end(args);
}
static Request *info(NMActRequest *req) { return g_object_get_data(req, "info"); }
static NMConnection *nm_device_get_applied_connection(NMDevice *dev) { return &info(dev->req)->applied; }
static NMSettingWirelessSecurity *nm_connection_get_setting_wireless_security(NMConnection *c) { return c->security; }
static const char *nm_setting_wireless_security_get_key_mgmt(NMSettingWirelessSecurity *s) { return s->key_mgmt; }
static const char *nm_setting_wireless_security_get_psk(NMSettingWirelessSecurity *s) { return s->psk; }
static unsigned nm_setting_wireless_security_get_psk_flags(NMSettingWirelessSecurity *s) { return s->flags; }
static int nm_device_get_state(NMDevice *dev) { return dev->state; }
static NMActRequest *nm_device_get_act_request(NMDevice *dev) { return dev->req; }
static int nm_active_connection_get_activation_reason(NMActRequest *req) { return info(req)->reason; }
static NMSettingsConnection *nm_act_request_get_settings_connection(NMActRequest *req) { return &info(req)->settings; }
static NMConnection *nm_act_request_get_applied_connection(NMActRequest *req) { return &info(req)->applied; }
static NMConnection *nm_settings_connection_get_connection(NMSettingsConnection *s) { return &s->connection; }
static gboolean nm_settings_connection_get_timestamp(NMSettingsConnection *s, guint64 *out) { *out=s->timestamp; return s->has_timestamp; }
static gboolean nm_device_is_activating(NMDevice *dev) { return dev->state==NM_DEVICE_STATE_CONFIG || dev->state==NM_DEVICE_STATE_NEED_AUTH; }
static void nm_act_request_clear_secrets(NMActRequest *req) {
    g_assert_true(req==d.req);
    d.clear++;
    applied.psk=NULL;
}
static void cleanup_association_attempt(NMDeviceWifi *self, gboolean disconnect) {
    g_assert_true(disconnect);
    self->cleanup++;
    self->priv.sup_timeout_id=0;
}
static void nm_device_state_changed(NMDevice *dev, int state, int reason) { dev->state=state; dev->reason=reason; }
static void wifi_secrets_get_secrets(NMDeviceWifi *self, const char *setting, unsigned flags) {
    g_assert_cmpstr(setting, ==, "wireless-security");
    self->new_secrets=!!(flags & NM_SECRET_AGENT_GET_SECRETS_FLAG_REQUEST_NEW);
    self->secrets++;
}
static gboolean need_new_8021x_secrets(NMDeviceWifi *self, int old, const char **setting) {
    if (self->enterprise) *setting="wireless-security";
    return self->enterprise;
}
/* Record the requested secret policy. Real async settings/agent delivery and
 * auth-retries accounting are covered by daemon hardware tests, not this stub. */
static gboolean handle_auth_or_fail(NMDeviceWifi *self, NMActRequest *req, gboolean new_secrets) {
    self->auth++;
    self->new_secrets=new_secrets;
    if (!self->auth_available) return FALSE;
    nm_act_request_clear_secrets(req);
    self->state=NM_DEVICE_STATE_NEED_AUTH;
    return TRUE;
}
#include "handlers.inc"

static void setup(void) {
    g_clear_object(&d.req);
    memset(&d, 0, sizeof(d));
    memset(&r, 0, sizeof(r));
    if (!messages) messages=g_string_new(NULL);
    g_string_truncate(messages, 0);
    stored=(NMSettingWirelessSecurity){"wpa-psk", "test-only-secret", 0};
    applied=stored;
    r.settings=(NMSettingsConnection){{&stored}, 123, TRUE};
    r.applied.security=&applied;
    r.reason=NM_ACTIVATION_REASON_AUTOCONNECT;
    d.req=g_object_new(G_TYPE_OBJECT, NULL);
    g_object_set_data(d.req, "info", &r);
    d.state=NM_DEVICE_STATE_CONFIG;
    d.priv=(NMDeviceWifiPrivate){_NM_802_11_MODE_INFRA, 42, TRUE};
    d.auth_available=TRUE;
}
static gboolean disconnect_reason(int reason) {
    return handle_8021x_or_psk_auth_fail(&d, NM_SUPPLICANT_INTERFACE_STATE_DISCONNECTED,
                                      NM_SUPPLICANT_INTERFACE_STATE_4WAY_HANDSHAKE, reason);
}
static void mismatch(void) { supplicant_iface_notify_wpa_psk_mismatch_cb(NULL, &d); }
static void expect_retained(void) {
    g_assert_cmpuint(d.clear, ==, 0);
    g_assert_cmpuint(d.secrets, ==, 0);
    g_assert_cmpuint(d.cleanup, ==, 0);
    g_assert_cmpuint(d.priv.sup_timeout_id, ==, 42);
    g_assert_cmpint(d.state, ==, NM_DEVICE_STATE_CONFIG);
    g_assert_cmpstr(applied.psk, ==, stored.psk);
}
static void expect_prompt(void) {
    g_assert_cmpuint(d.clear, ==, 1);
    g_assert_cmpuint(d.secrets, ==, 1);
    g_assert_true(d.new_secrets);
    g_assert_null(applied.psk);
    g_assert_nonnull(stored.psk); /* applied clearing does not erase the saved key */
    g_assert_cmpint(d.state, ==, NM_DEVICE_STATE_NEED_AUTH);
}
static void both_orders(void) {
    for (int order=0; order<2; order++) {
        setup();
        for (int event=0; event<6; event++) {
            if (order) mismatch();
            g_assert_false(disconnect_reason(15));
            if (!order) mismatch();
            expect_retained();
        }
    }
}
static void manual(void) { setup(); r.reason=0; mismatch(); g_assert_false(disconnect_reason(15)); expect_retained(); }
static void timeout_retry(void) {
    for (int history=0; history<3; history++) {
        setup();
        r.settings.has_timestamp=history!=0;
        r.settings.timestamp=history==2 ? 123 : 0;
        mismatch();
        g_assert_false(supplicant_connection_timeout_cb(&d));
        g_assert_cmpuint(d.auth, ==, 1);
        g_assert_false(d.new_secrets);
        g_assert_cmpint(d.state, ==, NM_DEVICE_STATE_NEED_AUTH);
        g_assert_nonnull(strstr(messages->str, "retrying association with stored PSK"));
    }
}
static void retry_bound(void) {
    setup();
    stored.psk=applied.psk="deliberately-wrong-test-key";
    for (unsigned window=0; window<3; window++) {
        g_assert_false(supplicant_connection_timeout_cb(&d));
        if (window<2) {
            g_assert_cmpuint(d.auth, ==, window+1);
            g_assert_false(d.new_secrets);
            g_assert_cmpint(d.state, ==, NM_DEVICE_STATE_NEED_AUTH);
            /* Model cached-secret delivery and CONFIG reentry on SAME request. */
            applied.psk=stored.psk;
            d.state=NM_DEVICE_STATE_CONFIG;
            d.priv.sup_timeout_id=42;
            mismatch();
            g_assert_false(disconnect_reason(15));
            g_assert_cmpuint(d.secrets, ==, 0);
        }
    }
    g_assert_cmpuint(d.auth, ==, 2);
    g_assert_cmpint(d.state, ==, NM_DEVICE_STATE_FAILED);
    g_assert_cmpint(d.reason, ==, NM_DEVICE_STATE_REASON_SUPPLICANT_TIMEOUT);
    g_assert_nonnull(strstr(messages->str, "retries exhausted"));
    setup();
    supplicant_connection_timeout_cb(&d);
    g_assert_cmpuint(d.auth, ==, 1); /* new request gets its own retry budget */
}
static void lower_auth_budget(void) {
    setup(); d.auth_available=FALSE;
    supplicant_connection_timeout_cb(&d);
    g_assert_cmpuint(d.auth, ==, 1);
    g_assert_cmpuint(d.clear, ==, 0);
    g_assert_cmpint(d.state, ==, NM_DEVICE_STATE_FAILED);
    g_assert_cmpint(d.reason, ==, NM_DEVICE_STATE_REASON_SUPPLICANT_TIMEOUT);
}
static void missing_ssid(void) {
    setup(); mismatch(); expect_retained(); d.priv.ssid_found=FALSE;
    supplicant_connection_timeout_cb(&d);
    g_assert_cmpuint(d.auth, ==, 0);
    g_assert_cmpint(d.state, ==, NM_DEVICE_STATE_FAILED);
    g_assert_cmpint(d.reason, ==, NM_DEVICE_STATE_REASON_SSID_NOT_FOUND);
    g_assert_nonnull(strstr(messages->str, "association took too long, failing activation"));
}
static void cancelled(void) {
    setup(); d.state=NM_DEVICE_STATE_FAILED;
    mismatch(); g_assert_false(disconnect_reason(15));
    supplicant_connection_timeout_cb(&d);
    g_assert_cmpuint(d.auth, ==, 0);
    g_assert_cmpuint(d.secrets, ==, 0);
    g_assert_cmpuint(d.clear, ==, 0);
}
static void excluded_keys(void) {
    for (int scenario=0; scenario<13; scenario++) {
        for (int event=0; event<2; event++) {
            setup();
            switch (scenario) {
            case 0: r.settings.connection.security=NULL; break;
            case 1: stored.psk=NULL; break;
            case 2: stored.psk=""; break;
            case 3: applied.psk=NULL; break;
            case 4: applied.psk="changed-key"; break;
            case 5: stored.key_mgmt="sae"; break;
            case 6: stored.flags=1; break;
            case 7: stored.flags=2; break;
            case 8: stored.flags=4; break;
            case 9: applied.flags=1; break;
            case 10: applied.flags=2; break;
            case 11: applied.flags=4; break;
            case 12: d.priv.sup_timeout_id=0; break;
            }
            if (event) mismatch(); else g_assert_true(disconnect_reason(15));
            if (!stored.psk) stored.psk="placeholder-for-saved-key-assert";
            expect_prompt();
        }
    }
}
static void other_modes(void) {
    for (int mode=2; mode<=4; mode++) {
        setup(); d.priv.mode=mode; mismatch(); expect_prompt();
        setup(); d.priv.mode=mode; supplicant_connection_timeout_cb(&d);
        g_assert_cmpuint(d.auth, ==, 0);
        g_assert_cmpint(d.reason, ==, NM_DEVICE_STATE_REASON_SUPPLICANT_TIMEOUT);
    }
}
static void other_auth(void) {
    setup(); d.enterprise=TRUE; g_assert_true(disconnect_reason(15)); expect_prompt();
    setup(); applied.key_mgmt="sae"; g_assert_false(disconnect_reason(15));
    mismatch(); expect_prompt();
    setup(); stored.flags=applied.flags=1; r.settings.timestamp=0;
    supplicant_connection_timeout_cb(&d); g_assert_true(d.new_secrets);
    setup(); stored.flags=applied.flags=1;
    supplicant_connection_timeout_cb(&d); g_assert_false(d.new_secrets);
}
static void other_reasons(void) {
    setup(); g_assert_true(disconnect_reason(-15)); expect_prompt();
    setup(); g_assert_true(disconnect_reason(2)); expect_prompt();
    setup(); g_assert_false(disconnect_reason(-4)); expect_retained();
}
static void activated(void) {
    setup(); d.state=NM_DEVICE_STATE_ACTIVATED;
    mismatch(); g_assert_false(disconnect_reason(15));
    g_assert_cmpuint(d.clear, ==, 0);
    g_assert_cmpuint(d.secrets, ==, 0);
}
int main(int argc, char **argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/recovery/both-event-orders-repeated", both_orders);
    g_test_add_func("/recovery/manual-saved-profile", manual);
    g_test_add_func("/recovery/timeout-all-timestamp-states", timeout_retry);
    g_test_add_func("/recovery/wrong-key-bounded-across-reentry", retry_bound);
    g_test_add_func("/recovery/lower-auth-budget", lower_auth_budget);
    g_test_add_func("/recovery/missing-ssid", missing_ssid);
    g_test_add_func("/unchanged/cancelled", cancelled);
    g_test_add_func("/unchanged/excluded-keys", excluded_keys);
    g_test_add_func("/unchanged/other-modes", other_modes);
    g_test_add_func("/unchanged/other-auth", other_auth);
    g_test_add_func("/unchanged/other-disconnect-reasons", other_reasons);
    g_test_add_func("/unchanged/already-connected", activated);
    int result=g_test_run();
    g_clear_object(&d.req);
    if (messages) g_string_free(messages, TRUE);
    return result;
}
