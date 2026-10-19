/* Actual expiry predicate: cancellation callbacks may own the queue mutex.
 * Reading expiry must neither acquire that mutex nor inspect stale queue data.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef uint8_t u8;
struct delayed_work { bool pending; };
struct hci_dev {
    u8 expired_adv_instance;
    u8 adv_instance_expire_retries;
    bool adv_instance_expire_armed;
    unsigned long adv_instance_expire_deadline;
    unsigned adv_instance_timeout;
    struct delayed_work adv_instance_expire;
};
static unsigned long jiffies;
#define time_after_eq(a,b) ((long)((a)-(b)) >= 0)
static bool cancel_delayed_work(struct delayed_work *w) { bool p=w->pending; w->pending=false; return p; }
#define msecs_to_jiffies(ms) (ms)
/* BODY: adv_timeout_retry_delay */
/* BODY: hci_legacy_scan_adv_expired */
/* BODY: cancel_adv_timeout */
/* BODY: mgmt_cancel_adv_timeout */
#define CHECK(e) do { if (!(e)) { fprintf(stderr,"line %d: %s\n",__LINE__,#e); failures++; } } while (0)
int main(void) {
    int failures=0;
    struct hci_dev h={0};
    unsigned expected[]={100,200,400,800,1600,3200,3200,3200};
    for (unsigned i=0;i<sizeof(expected)/sizeof(expected[0]);i++)
        CHECK(adv_timeout_retry_delay(&h)==expected[i]);
    for (int i=0;i<1000;i++) CHECK(adv_timeout_retry_delay(&h)==3200);
    jiffies=3000;
    CHECK(!hci_legacy_scan_adv_expired(&h,1)); /* unlimited/unarmed */
    h.expired_adv_instance=1;
    CHECK(hci_legacy_scan_adv_expired(&h,1)); /* successful enqueue, timer disarmed */
    h.adv_instance_expire_armed=true;
    h.adv_instance_expire_deadline=4000;
    CHECK(hci_legacy_scan_adv_expired(&h,1)); /* failed allocation retry moved timer */
    h.expired_adv_instance=0;
    CHECK(!hci_legacy_scan_adv_expired(&h,1)); /* fresh future slice */
    h.adv_instance_expire_deadline=3000;
    CHECK(hci_legacy_scan_adv_expired(&h,1)); /* zero-delay/deadline boundary */
    h.adv_instance_expire_deadline=2999;
    CHECK(hci_legacy_scan_adv_expired(&h,1)); /* timer waiting for device lock */
    h.expired_adv_instance=2;h.adv_instance_expire_armed=false;
    CHECK(!hci_legacy_scan_adv_expired(&h,1)); /* another completed slice */
    for (int management=0;management<2;management++) {
        h.expired_adv_instance=1;h.adv_instance_expire_armed=true;
        h.adv_instance_timeout=2;h.adv_instance_expire.pending=true;
        if (management) mgmt_cancel_adv_timeout(&h); else cancel_adv_timeout(&h);
        CHECK(!hci_legacy_scan_adv_expired(&h,1));
        CHECK(!h.expired_adv_instance && !h.adv_instance_expire_armed);
        CHECK(!h.adv_instance_timeout && !h.adv_instance_expire.pending);
    }
    printf("9 expiry authority scenarios and capped retry backoff: %d failed assertions\n",failures);
    return failures ? 86 : 0;
}
