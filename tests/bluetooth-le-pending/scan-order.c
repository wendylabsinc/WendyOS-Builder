/* Actual pinned functions are inserted by run-scan-order.py. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
typedef uint8_t u8;
typedef unsigned int bdaddr_t;
enum { HCI_LE_SCAN, HCI_LE_ADV, HCI_LE_SCAN_INTERRUPTED, HCI_MESH,
       HCI_LE_SIMULTANEOUS_ROLES, HCI_CONN_SCANNING };
enum { LE_SCAN_DISABLE, LE_SCAN_ENABLE, LE_SCAN_ACTIVE=1, DISCOVERY_STOPPED=0,
       DISCOVERY_FINDING=1, HCI_ROLE_MASTER=0, HCI_ROLE_SLAVE=1, BT_CONNECT=5,
       LE_LINK=1, HCI_OP_LE_CREATE_CONN=0x200d, HCI_EV_LE_ENHANCED_CONN_COMPLETE=10,
       HCI_EV_LE_CONN_COMPLETE=1 };
struct discovery_state { int state; bdaddr_t last_adv_addr; int last_adv_addr_type,
 last_adv_rssi, last_adv_flags; char last_adv_data[31]; int last_adv_data_len; };
struct hci_dev { unsigned long flags; struct discovery_state discovery;
 bool scanning_paused; int le_scan_type, workqueue, reenable_adv_work, le_scan_disable;
 int le_conn_min_interval,le_conn_max_interval,le_conn_latency,le_supv_timeout;
 int le_scan_int_connect,le_scan_window_connect; };
struct hci_conn { unsigned long flags; int state,role; bdaddr_t dst; int dst_type;
 int le_conn_min_interval,le_conn_max_interval,le_conn_latency,le_supv_timeout;
 int conn_timeout; };
struct hci_conn_params { int conn_min_interval,conn_max_interval,conn_latency,
 supervision_timeout; };
struct hci_cp_le_create_conn { int scan_interval,scan_window; bdaddr_t peer_addr;
 int peer_addr_type,own_address_type,conn_interval_min,conn_interval_max,
 conn_latency,supervision_timeout,min_ce_len,max_ce_len; };
static int disable_error,create_error,disable_calls,creates,cancels,resumes,queued;
static int stops,ext_conn,failures,cases;
#define bt_dev_dbg(...) ((void)0)
#define bt_dev_err(...) ((void)0)
#define hci_dev_lock(d) ((void)(d))
#define hci_dev_unlock(d) ((void)(d))
#define cpu_to_le16(v) (v)
#define bacpy(d,s) (*(d)=*(s))
#define cancel_delayed_work(...) ((void)0)
#define clear_pending_adv_report(...) ((void)0)
#define mgmt_device_found(dev,addr,...) ((void)(addr))
static int hci_dev_test_flag(struct hci_dev *d,int f) { return !!(d->flags&(1ul<<f)); }
static void hci_dev_set_flag(struct hci_dev *d,int f) { d->flags|=1ul<<f; }
static void hci_dev_clear_flag(struct hci_dev *d,int f) { d->flags&=~(1ul<<f); }
static int hci_dev_test_and_clear_flag(struct hci_dev *d,int f) {
 int v=hci_dev_test_flag(d,f);hci_dev_clear_flag(d,f);return v; }
static void clear_bit(int f,unsigned long *v) { *v&=~(1ul<<f); }
static int has_pending_adv_report(struct hci_dev *d) { return 0; }
static void hci_discovery_set_state(struct hci_dev *d,int s) { d->discovery.state=s;stops++; }
static int queue_work(int q,int *w) { queued++;return 1; }
static int hci_conn_valid(struct hci_dev *d,struct hci_conn *c) { return 1; }
static void hci_conn_del(struct hci_conn *c) {}
static struct hci_conn_params *hci_conn_params_lookup(struct hci_dev *d,bdaddr_t *b,int t) { return NULL; }
static int hci_pause_advertising_sync(struct hci_dev *d) {
 hci_dev_clear_flag(d,HCI_LE_ADV);return 0; }
static int hci_resume_advertising_sync(struct hci_dev *d) {
 resumes++;hci_dev_set_flag(d,HCI_LE_ADV);return 0; }
static int conn_use_rpa(struct hci_conn *c) { return 0; }
static int hci_update_random_address_sync(struct hci_dev *d,bool p,int r,u8 *a) { *a=0;return 0; }
static int use_ext_conn(struct hci_dev *d) { return ext_conn; }
static int hci_le_ext_create_conn_sync(struct hci_dev *d,struct hci_conn *c,u8 a) { creates++;return create_error; }
static int hci_le_directed_advertising_sync(struct hci_dev *d,struct hci_conn *c) { creates++;return create_error; }
static int use_enhanced_conn_complete(struct hci_dev *d) { return 1; }
static int __hci_cmd_sync_status_sk(struct hci_dev *d,int op,int len,void *cp,int ev,int timeout,void *sk) { creates++;return create_error; }
static int hci_le_connect_cancel_sync(struct hci_dev *d,struct hci_conn *c,u8 why) { cancels++;return 0; }
/* EVENT_HANDLER */
static int hci_le_set_scan_enable_sync(struct hci_dev *d,u8 val,u8 dup) {
 disable_calls++;
 if(disable_error)return disable_error;
 /* Completion is dispatched inside the synchronous call, as in the kernel. */
 le_set_scan_enable_complete(d,val);
 return 0;
}
/* SCAN_DISABLE */
/* CREATE_CONN */
#define CHECK(expr) do { if(!(expr)) { failures++;printf("%s: line%d: %s\n",name,__LINE__,#expr); } } while(0)
static void test_case(const char *name,bool scanning,bool paused,int disable,int create,int ext,bool simultaneous) {
 struct hci_dev d={0};struct hci_conn c={.role=HCI_ROLE_MASTER};
 disable_error=disable;create_error=create;ext_conn=ext;
 disable_calls=creates=cancels=resumes=queued=stops=0;cases++;
 d.discovery.state=DISCOVERY_FINDING;d.scanning_paused=paused;d.le_scan_type=LE_SCAN_ACTIVE;
 hci_dev_set_flag(&d,HCI_LE_ADV);
 if(scanning)hci_dev_set_flag(&d,HCI_LE_SCAN);
 if(simultaneous)hci_dev_set_flag(&d,HCI_LE_SIMULTANEOUS_ROLES);
 int err=hci_le_create_conn_sync(&d,&c);
 bool command=scanning&&!paused;
 CHECK(!hci_dev_test_flag(&d,HCI_LE_SCAN_INTERRUPTED));
 CHECK(disable_calls==(int)command);
 CHECK(queued==0);
 CHECK(resumes==1); /* existing advertising restoration called once */
 if(command&&disable) {
  CHECK(err==disable);CHECK(creates==0);CHECK(cancels==0);
  CHECK(d.discovery.state==DISCOVERY_FINDING&&stops==0);
 } else {
  CHECK(err==create);CHECK(creates==1);CHECK(cancels==(create==-ETIMEDOUT));
  CHECK(d.discovery.state==(command?DISCOVERY_STOPPED:DISCOVERY_FINDING));
  CHECK(stops==(int)command);
 }
 /* A later unrelated disable must not consume a leaked interruption token. */
 if(!command||disable) {
  hci_dev_set_flag(&d,HCI_LE_SCAN);hci_dev_clear_flag(&d,HCI_LE_ADV);
  le_set_scan_enable_complete(&d,LE_SCAN_DISABLE);
  CHECK(queued==1&&d.discovery.state==DISCOVERY_FINDING);
 }
}
int main(void) {
 test_case("extended-success",true,false,0,0,1,false);
 test_case("legacy-success",true,false,0,0,0,false);
 test_case("simultaneous-success",true,false,0,0,1,true);
 test_case("not-scanning",false,false,0,0,1,false);
 test_case("paused-no-completion",true,true,0,0,1,false);
 test_case("disable-controller-status",true,false,12,0,1,false);
 test_case("disable-EIO",true,false,-EIO,0,1,false);
 test_case("disable-timeout",true,false,-ETIMEDOUT,0,1,false);
 test_case("disable-cancelled",true,false,-ECANCELED,0,1,false);
 test_case("create-timeout",true,false,0,-ETIMEDOUT,1,false);
 test_case("create-EIO",true,false,0,-EIO,1,false);
 test_case("legacy-create-timeout",true,false,0,-ETIMEDOUT,0,false);
 printf("cases=%d failures=%d\n",cases,failures);
 return failures?86:0;
}
