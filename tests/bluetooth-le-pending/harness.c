
#include <errno.h>
#include <stdio.h>
#define BT_CONNECT 5
#define BT_CONNECTED 1
struct work { int flushed; };
struct hci_conn { int state, valid, failed, cleaned, puts; struct work le_conn_timeout; };
struct hci_dev { struct hci_conn *first; int depth, locks; };
#define bt_dev_dbg(...) ((void)0)
#define hci_lookup_le_connect(dev) ((dev)->first)
#define hci_conn_valid(dev, conn) ((void)(dev), (conn)->valid)
static void hci_dev_lock(struct hci_dev *d) { d->depth++; d->locks++; }
static void hci_dev_unlock(struct hci_dev *d) { d->depth--; }
static void hci_connect_le_scan_cleanup(struct hci_conn *c, int status) { c->cleaned++; (void)status; }
static void flush_delayed_work(struct work *w) { w->flushed++; }
static void hci_conn_put(struct hci_conn *c) { c->puts++; }
static int bt_status(int error) { return error; }
static void hci_conn_failed(struct hci_conn *c, int status) { c->failed++; c->state=0; (void)status; }
/* CALLBACK */

int main(void) {
    int failures=0;
    for (int test=0; test<7; test++) {
        struct hci_conn first={.state=BT_CONNECT,.valid=1};
        struct hci_conn target={.state=BT_CONNECT,.valid=1};
        struct hci_dev d={.first=&first};
        int error=-EPROTO, failed=0, cleaned=0, locks=1;
        const char *name="second pending connection must retire";
        switch(test) {
        case 0: failed=1; break;
        case 1: name="first pending connection must retire"; d.first=&target; failed=1; break;
        case 2: name="successful connection cleans scan state"; error=0; cleaned=1; break;
        case 3: name="cancelled command preserves callback ownership"; error=-ECANCELED; locks=0; break;
        case 4: name="deleted connection is untouched"; target.valid=0; break;
        case 5: name="established connection is untouched by late error"; target.state=BT_CONNECTED; break;
        case 6: name="pending connection retires without a device lookup match"; d.first=NULL; failed=1; break;
        }
        create_le_conn_complete(&d,&target,error);
        int ok=target.failed==failed && target.le_conn_timeout.flushed==failed &&
            target.cleaned==cleaned && first.failed==0 && first.le_conn_timeout.flushed==0 &&
            d.depth==0 && d.locks==locks && target.puts==EXPECT_PUTS;
        printf("%s: %s (failed=%d flushed=%d cleaned=%d)\n",ok?"PASS":"FAIL",name,
               target.failed,target.le_conn_timeout.flushed,target.cleaned);
        failures+=!ok;
    }
    return failures?86:0;
}
