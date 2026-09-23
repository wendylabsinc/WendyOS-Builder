#include <glib-object.h>
#include <string.h>
#include <stdio.h>
typedef int NMSupplicantInterfaceState;
typedef int NMSupplicantInterface;
typedef struct { const char *key_mgmt, *psk; unsigned flags; } NMSettingWirelessSecurity;
typedef struct { NMSettingWirelessSecurity *security; } NMConnection;
typedef struct { NMConnection connection; guint64 timestamp; gboolean has_timestamp; } NMSettingsConnection;
typedef GObject NMActRequest;
typedef struct { NMSettingsConnection settings; NMConnection applied; int reason; } Request;
typedef struct { int mode; guint sup_timeout_id; gboolean ssid_found; } NMDeviceWifiPrivate;
typedef struct { NMDeviceWifiPrivate priv; NMActRequest *req; int state, reason; unsigned cleanup, clear, secrets, auth; gboolean enterprise; } NMDeviceWifi;
typedef NMDeviceWifi NMDevice;
#define NM_DEVICE_WIFI_GET_PRIVATE(s) (&(s)->priv)
#define NM_DEVICE(s) (s)
#define NM_DEVICE_WIFI(s) ((NMDeviceWifi *)(s))
#define NM_ACTIVE_CONNECTION(r) (r)
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
#define NM_ACTIVATION_REASON_AUTOCONNECT 1
#define NM_SETTING_SECRET_FLAG_NONE 0
#define NM_SETTING_WIRELESS_SECURITY_SETTING_NAME "wireless-security"
#define NM_SECRET_AGENT_GET_SECRETS_FLAG_ALLOW_INTERACTION 1
#define NM_SECRET_AGENT_GET_SECRETS_FLAG_REQUEST_NEW 2
#define NM_IN_SET(x,a,b,c) ((x)==(a)||(x)==(b)||(x)==(c))
#define _LOGI(...) ((void)0)
#define _LOGW(...) ((void)0)
static NMDeviceWifi *current;
static Request *info(NMActRequest *r) { return g_object_get_data(r,"info"); }
static NMConnection *nm_device_get_applied_connection(NMDevice *d) { return &info(d->req)->applied; }
static NMSettingWirelessSecurity *nm_connection_get_setting_wireless_security(NMConnection *c) { return c->security; }
static const char *nm_setting_wireless_security_get_key_mgmt(NMSettingWirelessSecurity *s) { return s->key_mgmt; }
static const char *nm_setting_wireless_security_get_psk(NMSettingWirelessSecurity *s) { return s->psk; }
static unsigned nm_setting_wireless_security_get_psk_flags(NMSettingWirelessSecurity *s) { return s->flags; }
static int nm_device_get_state(NMDevice *d) { return d->state; }
static NMActRequest *nm_device_get_act_request(NMDevice *d) { return d->req; }
static int nm_active_connection_get_activation_reason(NMActRequest *r) { return info(r)->reason; }
static NMSettingsConnection *nm_act_request_get_settings_connection(NMActRequest *r) { return &info(r)->settings; }
static NMConnection *nm_act_request_get_applied_connection(NMActRequest *r) { return &info(r)->applied; }
static NMConnection *nm_settings_connection_get_connection(NMSettingsConnection *s) { return &s->connection; }
static gboolean nm_settings_connection_get_timestamp(NMSettingsConnection *s, guint64 *out) { *out=s->timestamp;return s->has_timestamp; }
static gboolean nm_device_is_activating(NMDevice *d) { return d->state==NM_DEVICE_STATE_CONFIG || d->state==NM_DEVICE_STATE_NEED_AUTH; }
static void nm_act_request_clear_secrets(NMActRequest *r) { g_assert(r==current->req);current->clear++; }
static void cleanup_association_attempt(NMDeviceWifi *s, gboolean disconnect) { g_assert(disconnect);s->cleanup++;s->priv.sup_timeout_id=0; }
static void nm_device_state_changed(NMDevice *d, int state, int reason) { d->state=state;d->reason=reason; }
static void wifi_secrets_get_secrets(NMDeviceWifi *s, const char *setting, unsigned flags) { g_assert_cmpstr(setting,==,"wireless-security");g_assert(flags&NM_SECRET_AGENT_GET_SECRETS_FLAG_REQUEST_NEW);s->secrets++; }
static gboolean need_new_8021x_secrets(NMDeviceWifi *s, int old, const char **setting) { if(s->enterprise)*setting="wireless-security";return s->enterprise; }
static gboolean handle_auth_or_fail(NMDeviceWifi *s, NMActRequest *req, gboolean new_secrets) { s->auth++; return TRUE; }
/* Exact unmodified function bodies are generated from the recipe-patched source. */
#include "handlers.inc"
static NMDeviceWifi d;
static Request r;
static NMSettingWirelessSecurity stored, applied;
static void setup(void) {
 if(d.req)g_object_unref(d.req);
 memset(&d,0,sizeof(d));memset(&r,0,sizeof(r));
 stored=(NMSettingWirelessSecurity){"wpa-psk","test-only-secret",0};applied=stored;
 r.settings=(NMSettingsConnection){{&stored},123,TRUE};r.applied.security=&applied;r.reason=NM_ACTIVATION_REASON_AUTOCONNECT;
 d.req=g_object_new(G_TYPE_OBJECT,NULL);g_object_set_data(d.req,"info",&r);
 d.state=NM_DEVICE_STATE_CONFIG;d.priv.mode=_NM_802_11_MODE_INFRA;d.priv.sup_timeout_id=42;d.priv.ssid_found=TRUE;current=&d;
}
static gboolean disconnect_reason(int reason) { return handle_8021x_or_psk_auth_fail(&d,5,4,reason); }
static void expect_prompt(void) { g_assert_true(disconnect_reason(15));g_assert_cmpuint(d.secrets,==,1);g_assert_cmpuint(d.clear,==,1);g_assert_cmpint(d.state,==,NM_DEVICE_STATE_NEED_AUTH); }
static void allow(void) { g_assert_false(disconnect_reason(15));g_assert_cmpuint(d.clear,==,0);g_assert_cmpuint(d.secrets,==,0);g_assert_cmpuint(d.cleanup,==,0);g_assert_cmpuint(d.priv.sup_timeout_id,==,42);g_assert_cmpint(d.state,==,NM_DEVICE_STATE_CONFIG); }
int main(void) {
 setup(); allow();puts("PASS first known-key timeout leaves original timer and secrets intact");
 expect_prompt();puts("PASS second timeout in same request uses original prompt path");
 setup();allow();d.state=NM_DEVICE_STATE_CONFIG;expect_prompt();puts("PASS stage reentry cannot replenish request budget");
 setup();allow();setup();allow();puts("PASS genuinely new request receives new single allowance");
 setup();allow();supplicant_iface_notify_wpa_psk_mismatch_cb(NULL,&d);g_assert_cmpuint(d.secrets,==,1);g_assert_cmpint(d.state,==,NM_DEVICE_STATE_NEED_AUTH);puts("PASS explicit mismatch after allowance still requests new secret");
 setup();supplicant_iface_notify_wpa_psk_mismatch_cb(NULL,&d);g_assert_cmpuint(d.secrets,==,1);g_assert_cmpint(d.state,==,NM_DEVICE_STATE_NEED_AUTH);puts("PASS explicit mismatch before allowance unchanged");
 setup();allow();g_assert_false(supplicant_connection_timeout_cb(&d));g_assert_cmpint(d.state,==,NM_DEVICE_STATE_FAILED);g_assert_cmpint(d.reason,==,NM_DEVICE_STATE_REASON_SUPPLICANT_TIMEOUT);g_assert_cmpuint(d.auth,==,0);g_assert_cmpuint(d.secrets,==,0);puts("PASS original deadline fails without restarting auth-retries loop");
 setup();allow();d.state=NM_DEVICE_STATE_FAILED;g_assert_false(disconnect_reason(15));g_assert_false(supplicant_connection_timeout_cb(&d));g_assert_cmpuint(d.secrets,==,0);g_assert_cmpuint(d.auth,==,0);puts("PASS cancellation cannot trigger recovery");
 setup();r.settings.timestamp=0;allow();setup();r.settings.has_timestamp=FALSE;allow();puts("PASS stored-key profile without prior-success history receives one allowance");
 setup();stored.psk=applied.psk="known-wrong-test-key";allow();expect_prompt();puts("PASS stored wrong key without mismatch signal reaches prompt on second timeout");
 setup();stored.psk=applied.psk="known-wrong-test-key";allow();supplicant_connection_timeout_cb(&d);g_assert_cmpint(d.state,==,NM_DEVICE_STATE_FAILED);g_assert_cmpint(d.reason,==,NM_DEVICE_STATE_REASON_SUPPLICANT_TIMEOUT);g_assert_cmpuint(d.auth,==,0);puts("PASS stored wrong key without mismatch signal fails at original deadline");
 setup();stored.psk=NULL;expect_prompt();setup();stored.psk="";expect_prompt();setup();applied.psk=NULL;expect_prompt();setup();applied.psk="changed";expect_prompt();puts("PASS absent or changed stored/applied secrets rejected");
 for(unsigned flag=1;flag<=4;flag*=2){setup();stored.flags=flag;expect_prompt();setup();applied.flags=flag;expect_prompt();}puts("PASS agent-owned/not-saved/not-required secrets excluded on both copies");
 setup();r.reason=0;expect_prompt();setup();d.priv.sup_timeout_id=0;expect_prompt();puts("PASS user activation and expired association excluded");
 for(int mode=2;mode<=4;mode++){setup();d.priv.mode=mode;expect_prompt();}puts("PASS mesh/AP/adhoc modes excluded");
 setup();g_assert_true(disconnect_reason(-15));setup();g_assert_true(disconnect_reason(2));setup();g_assert_false(disconnect_reason(-4));g_assert_cmpuint(d.clear,==,0);puts("PASS only remote reason15 changes, local inactivity retained");
 setup();d.enterprise=TRUE;expect_prompt();setup();stored.key_mgmt="sae";expect_prompt();setup();applied.key_mgmt="sae";g_assert_false(disconnect_reason(15));puts("PASS enterprise/other key management unchanged");
 setup();r.settings.connection.security=NULL;expect_prompt();setup();d.state=NM_DEVICE_STATE_ACTIVATED;g_assert_false(disconnect_reason(15));puts("PASS missing persistent security or already-connected state excluded");
 setup();supplicant_connection_timeout_cb(&d);g_assert_cmpuint(d.auth,==,1);puts("PASS unrelated association timeout retains upstream behavior");
 g_object_unref(d.req);d.req=NULL;puts("ALL 19 exact-source handler groups PASS");return 0;
}
