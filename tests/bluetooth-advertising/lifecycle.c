
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
typedef uint8_t u8;typedef uint16_t u16;
struct list_head {struct list_head *next,*prev;};
struct delayed_work {bool pending;unsigned long expires;};
struct adv_info {struct list_head list;u8 instance;u16 timeout,duration,remaining_time;struct delayed_work rpa_expired_cb;};
struct hci_dev {struct list_head adv_instances;u8 cur_adv_instance,expired_adv_instance;bool adv_instance_expire_armed;unsigned long adv_instance_expire_deadline;u16 adv_instance_timeout;struct delayed_work adv_instance_expire;unsigned int adv_instance_cnt;unsigned flags;void *req_workqueue;int now,cancels,sync_cancels,disables,freed,starts,queued;};
enum {HCI_ADVERTISING,HCI_LE_ADV};
#define BT_DBG(...) ((void)0)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define list_for_each_entry_safe(p,n,h,m) for(struct list_head *pos=(h)->next,*nxt=pos->next;pos!=(h)&&((p)=container_of(pos,__typeof__(*(p)),m),(n)=nxt==(h)?NULL:container_of(nxt,__typeof__(*(n)),m),1);pos=nxt,nxt=pos->next)
static struct hci_dev *active;
static void init_list(struct list_head *h){h->next=h->prev=h;}
static void list_add_tail(struct list_head *n,struct list_head *h){n->next=h;n->prev=h->prev;h->prev->next=n;h->prev=n;}
static void list_del(struct list_head *n){n->prev->next=n->next;n->next->prev=n->prev;}
static void tracked_free(void *p){if(p){active->freed++;free(p);}}
#define kfree(p) tracked_free(p)
static bool cancel_delayed_work(struct delayed_work *w){bool was=w->pending;w->pending=false;active->cancels++;return was;}
static bool cancel_delayed_work_sync(struct delayed_work *w){active->sync_cancels++;return cancel_delayed_work(w);}
static bool disable_delayed_work(struct delayed_work *w){active->disables++;return cancel_delayed_work(w);}
static bool disable_delayed_work_sync(struct delayed_work *w){active->sync_cancels++;return disable_delayed_work(w);}
static bool queue_delayed_work(void *q,struct delayed_work *w,int t){(void)q;if(w->pending)return false;w->pending=true;if(t)w->expires=active->now+(unsigned long)t;active->queued++;return true;}
#define secs_to_jiffies(n) ((n)*1000)
static bool hci_dev_test_flag(struct hci_dev *h,int f){return (h->flags&(1u<<f))!=0;}
static bool ext_adv_capable(struct hci_dev *h){(void)h;return false;}
static struct adv_info *hci_find_adv_instance(struct hci_dev *h,u8 id){for(struct list_head *n=h->adv_instances.next;n!=&h->adv_instances;n=n->next){struct adv_info *a=container_of(n,struct adv_info,list);if(a->instance==id)return a;}return NULL;}
static int hci_start_adv_sync(struct hci_dev *h,u8 id){h->cur_adv_instance=id;h->starts++;h->flags|=1u<<HCI_LE_ADV;return 0;}

#define jiffies ((unsigned long)active->now)
static void hci_dev_lock(struct hci_dev *h){(void)h;}
static void hci_dev_unlock(struct hci_dev *h){(void)h;}
static bool delayed_work_pending(struct delayed_work *w){return w->pending;}
/* BODY: cancel_adv_timeout */
/* BODY: mgmt_cancel_adv_timeout */
/* BODY: hci_remove_adv_instance */
/* BODY: hci_adv_instances_clear */
/* BODY: hci_schedule_adv_instance_sync */
static void close_cleanup_exact(struct hci_dev *hdev)
{
	if (hdev->adv_instance_timeout || hdev->expired_adv_instance ||
	    hdev->adv_instance_expire_armed) {
		cancel_delayed_work_sync(&hdev->adv_instance_expire);
		hdev->adv_instance_timeout = 0;
		hdev->expired_adv_instance = 0;
		hdev->adv_instance_expire_armed = false;
	}
}


struct sock { int unused; };
static struct adv_info *hci_get_next_instance(struct hci_dev *h, u8 id) {
    for (struct list_head *n=h->adv_instances.next; n!=&h->adv_instances; n=n->next) {
        struct adv_info *a=container_of(n,struct adv_info,list);
        if (a->instance != id) return a;
    }
    return hci_find_adv_instance(h,id);
}
static void mgmt_advertising_removed(struct sock *s, struct hci_dev *h, u8 id) {(void)s;(void)h;(void)id;}
static bool hdev_is_powered(struct hci_dev *h) {(void)h;return true;}
/* BODY: hci_clear_adv_instance_sync */
static int hci_clear_adv_sync(struct hci_dev *h, struct sock *sk, bool force) {return hci_clear_adv_instance_sync(h,sk,0,force);}
static int hci_remove_adv_sync(struct hci_dev *h, u8 id, struct sock *sk) {(void)sk;return hci_remove_adv_instance(h,id);}
/* BODY: hci_remove_advertising_sync */
static void add(struct hci_dev *h, u8 id, unsigned remaining) {
    struct adv_info *a=calloc(1,sizeof(*a));
    a->instance=id;a->duration=2;a->timeout=10;a->remaining_time=remaining;
    list_add_tail(&a->list,&h->adv_instances);h->adv_instance_cnt++;
}
#define CHECK(expr) do { if (!(expr)) {fprintf(stderr,"case %d line %d: %s\n",which,__LINE__,#expr);failures++;} } while(0)
int main(void) {
 int failures=0;
 for(int test=0;test<16;test++) {
    int which=test%8;
    struct hci_dev h={.cur_adv_instance=2,.expired_adv_instance=1,.now=3000};
    active=&h;init_list(&h.adv_instances);add(&h,1,which==1?0:8);add(&h,2,8);
    h.adv_instance_timeout=which==3?2:0;
    h.adv_instance_expire_armed=which==3;
    h.adv_instance_expire.pending=which==3;
    h.adv_instance_expire_deadline=5000;h.adv_instance_expire.expires=5000;
    if (which==4) h.expired_adv_instance=2;
    if (which==5) h.cur_adv_instance=0;
    if (which==6) h.cur_adv_instance=1;
    if (which==2||which==3||which==4||which==6) {
        CHECK(hci_remove_adv_instance(&h,1)==0);
    } else {
        int rc = test < 8 ? hci_clear_adv_instance_sync(&h,NULL,which==7?3:1,false) :
            hci_remove_advertising_sync(&h,NULL,which==7?3:1,false);
        CHECK(rc==0);
    }
    if (which==4) CHECK(h.expired_adv_instance==2);
    else if (which==7) CHECK(h.expired_adv_instance==1);
    else CHECK(h.expired_adv_instance==0);
    if (which==3) {
        CHECK(h.cur_adv_instance==2 && h.adv_instance_timeout==2);
        CHECK(h.adv_instance_expire_armed && h.adv_instance_expire.pending);
        CHECK(h.adv_instance_expire_deadline==5000 && h.adv_instance_expire.expires==5000);
        CHECK(h.cancels==1); /* Only the removed instance's RPA callback. */
    } else if (which!=4 && which!=7) {
        CHECK(hci_schedule_adv_instance_sync(&h,2,true)==0);
        CHECK(h.cur_adv_instance==2 && h.adv_instance_expire_armed);
        CHECK(h.adv_instance_expire.pending && h.starts==1);
        CHECK(hci_find_adv_instance(&h,2)->remaining_time==6);
    }
    hci_adv_instances_clear(&h);
 }
 printf("advertising expiry: 16 cases, %d failures\n",failures);
 return failures?86:0;
}
