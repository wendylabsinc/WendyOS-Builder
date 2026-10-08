#!/usr/bin/env python3
"""Exercise interface control, STATUS and NAN/P2P teardown with mock radios.

Usage: python3 wendyos-nan-parent.test.py /path/to/patched/wpa_supplicant-2.12
Requires a C compiler. Driver stubs check selection/rollback, not radio behavior.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


HARNESS = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
typedef unsigned char u8;
#define ETH_ALEN 6
#define MSG_DEBUG 0
#define MSG_ERROR 1
#define MACSTR "%02x:%02x:%02x:%02x:%02x:%02x"
#define MAC2STR(a) (a)[0], (a)[1], (a)[2], (a)[3], (a)[4], (a)[5]
#define os_snprintf snprintf
#define os_strchr strchr
#define os_strcmp strcmp
#define os_memset memset
#define wpa_printf(...) ((void) 0)
enum wpa_driver_if_type { WPA_IF_STATION, WPA_IF_AP_BSS, WPA_IF_NAN,
                          WPA_IF_NAN_DATA };
struct wpa_interface {
    char *ifname, *confname, *driver, *ctrl_interface, *driver_param, *bridge_ifname;
    bool nan_mgmt, nan_data;
};
struct wpa_supplicant {
    const char *ifname;
    struct wpa_supplicant *next, *parent;
    unsigned int added_vif;
    void *radio;
    u8 own_addr[ETH_ALEN];
    bool nan_mgmt, nan_data, removed;
};
struct wpa_global { struct wpa_supplicant *ifaces; };
static struct wpa_supplicant wrong, wanted, created;
static struct wpa_supplicant *add_parent, *remove_parent;
static bool fail_register, saw_addr;
static enum wpa_driver_if_type added_type;
static char created_name[32];
static int phy0, phy1;
static int os_snprintf_error(size_t size, int ret)
{
    return ret < 0 || (size_t)ret >= size;
}
static const char *wpa_driver_get_radio_name(struct wpa_supplicant *s)
{
    return s->radio == &phy0 ? "phy0" : s->radio == &phy1 ? "phy1" : NULL;
}
static int hwaddr_aton(const char *s, u8 *addr)
{
    if (strcmp(s, "02:00:00:00:00:01"))
        return -1;
    memset(addr, 0, ETH_ALEN);
    addr[0] = 2;
    return 0;
}
static struct wpa_supplicant *
wpa_supplicant_get_iface(struct wpa_global *g, const char *name)
{
    struct wpa_supplicant *s;
    for (s = g->ifaces; s; s = s->next)
        if (!strcmp(s->ifname, name))
            return s;
    return NULL;
}
static int wpa_drv_if_add(struct wpa_supplicant *parent,
        enum wpa_driver_if_type type, const char *name, const u8 *addr,
        void *ctx, void **priv, u8 *out, const char *bridge)
{
    (void)name; (void)ctx; (void)priv; (void)bridge;
    add_parent = parent;
    added_type = type;
    saw_addr = addr != NULL;
    memset(out, 0, ETH_ALEN);
    return 0;
}
static int wpa_drv_if_remove(struct wpa_supplicant *parent,
        enum wpa_driver_if_type type, const char *name)
{
    (void)type; (void)name;
    assert(!parent->removed);
    remove_parent = parent;
    return 0;
}
static struct wpa_supplicant *
wpa_supplicant_add_iface(struct wpa_global *g, struct wpa_interface *iface,
                         struct wpa_supplicant *parent)
{
    (void)parent;
    if (fail_register)
        return NULL;
    snprintf(created_name, sizeof(created_name), "%s", iface->ifname);
    created.ifname = created_name;
    created.next = g->ifaces;
    created.radio = add_parent->radio;
    created.nan_mgmt = iface->nan_mgmt;
    created.nan_data = iface->nan_data;
    created.parent = &created;
    created.removed = false;
    g->ifaces = &created;
    return &created;
}
static int wpa_supplicant_remove_iface(struct wpa_global *g,
        struct wpa_supplicant *iface, int terminate)
{
    struct wpa_supplicant **p = &g->ifaces;
    (void)terminate;
    while (*p && *p != iface)
        p = &(*p)->next;
    assert(*p == iface);
    *p = iface->next;
    /* Model core teardown: recursively remove children before freeing their
     * parent. Poison removed contexts so the driver stub catches stale use. */
    for (;;) {
        struct wpa_supplicant *child;
        for (child = g->ifaces; child; child = child->next)
            if (child->parent == iface)
                break;
        if (!child)
            break;
        assert(wpa_supplicant_remove_iface(g, child, terminate) == 0);
    }
    iface->removed = true;
    return 0;
}
#include "interface-add.inc"
#include "global-status.inc"
static struct wpa_global reset(void)
{
    wanted = (struct wpa_supplicant){ .ifname = "wlan0", .radio = &phy0, .parent = &wanted };
    wrong = (struct wpa_supplicant){ .ifname = "wlan1", .next = &wanted, .radio = &phy1, .parent = &wrong };
    add_parent = remove_parent = NULL;
    fail_register = saw_addr = false;
    return (struct wpa_global){ .ifaces = &wrong };
}
static int add(struct wpa_global *g, const char *type, const char *addr,
               const char *parent)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "new0\t\tnl80211\t/ctrl\t\t\tcreate\t%s\t%s\t%s",
             type, addr, parent);
    return wpa_supplicant_global_iface_add(g, cmd);
}
int main(void)
{
    struct wpa_global g = reset();
    char status[512];
    struct wpa_supplicant child, grandchild;
    assert(add(&g, "nan", "", "wlan0") == 0);
    assert(add_parent == &wanted && added_type == WPA_IF_NAN && !saw_addr);
    assert(created.added_vif && !remove_parent);
    /* Removal must retain the right radio after unregistering the VIF,
     * even when the remaining list starts with the other radio. */
    assert(wpa_supplicant_global_iface_remove(&g, created_name) == 0);
    assert(remove_parent == &wanted && g.ifaces == &wrong);
    g = reset();
    wanted.ifname = "nan0";
    assert(add(&g, "nan_data", "", "nan0") == 0);
    assert(add_parent == &wanted && added_type == WPA_IF_NAN_DATA);
    g = reset();
    assert(add(&g, "nan", "", "missing") == -1);
    assert(!add_parent && !remove_parent);
    g = reset();
    fail_register = true;
    assert(add(&g, "nan", "", "wlan0") == -1);
    assert(add_parent == &wanted && remove_parent == &wanted);
    g = reset();
    assert(add(&g, "nan", "02:00:00:00:00:01", "wlan0") == 0);
    assert(add_parent == &wanted && saw_addr);
    g = reset();
    assert(add(&g, "nan", "invalid", "wlan0") == -1);
    assert(!add_parent && !remove_parent);
    g = reset();
    assert(add(&g, "nan", "", "") == 0);
    assert(add_parent == &wrong); /* Legacy requests retain their behavior. */
    /* Without a surviving driver context, refuse before unregistering. */
    wrong.radio = &phy0;
    wanted.radio = &phy0;
    assert(wpa_supplicant_global_iface_remove(&g, created_name) == -1);
    assert(g.ifaces == &created && !remove_parent);
    g = reset();
    /* The first same-radio candidate can be a child removed by teardown. */
    assert(add(&g, "sta", "", "wlan0") == 0);
    child = (struct wpa_supplicant){ .ifname = "p2p-child", .radio = &phy0,
        .parent = &created, .next = &wrong };
    grandchild = (struct wpa_supplicant){ .ifname = "p2p-group", .radio = &phy0,
        .parent = &child, .next = &child };
    created.next = &grandchild;
    assert(wpa_supplicant_global_iface_remove(&g, created_name) == 0);
    assert(remove_parent == &wanted && child.removed && grandchild.removed);
    assert(g.ifaces == &wrong);
    /* With only descendants on this radio, refuse before deleting anything. */
    g = reset();
    assert(add(&g, "sta", "", "wlan0") == 0);
    child = (struct wpa_supplicant){ .ifname = "p2p-child", .radio = &phy0,
        .parent = &created, .next = &wrong };
    created.next = &child;
    wanted.radio = &phy1;
    assert(wpa_supplicant_global_iface_remove(&g, created_name) == -1);
    assert(g.ifaces == &created && !created.removed && !child.removed);
    assert(!remove_parent);
    g = reset();
    wanted.ifname = "app-aware";
    wanted.nan_mgmt = true;
    assert(wpas_global_ctrl_iface_status(&g, status, sizeof(status)) > 0);
    assert(strstr(status, "ifname=app-aware\naddress=00:00:00:00:00:00\n"
                          "phyname=phy0\nnan_mgmt=1\nnan_data=0\n"));
    assert(strstr(status, "ifname=wlan1\naddress=00:00:00:00:00:00\n"
                          "phyname=phy1\nnan_mgmt=0\nnan_data=0\n"));
    wanted.nan_mgmt = false;
    wanted.nan_data = true;
    assert(wpas_global_ctrl_iface_status(&g, status, sizeof(status)) > 0);
    assert(strstr(status, "phyname=phy0\nnan_mgmt=0\nnan_data=1\n"));
    /* Even a driver without a radio name supplies authoritative type metadata. */
    wrong.radio = NULL;
    assert(wpas_global_ctrl_iface_status(&g, status, sizeof(status)) > 0);
    assert(strstr(status, "phyname=\nnan_mgmt=0\n"));
    puts("Interface parent/removal/rollback, legacy and STATUS type tests passed");
    return 0;
}
'''


P2P_HARNESS = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#define CONFIG_NAN
#define os_strcmp strcmp
#define wpa_printf(...) ((void) 0)
#define MSG_DEBUG 0
#define NOT_P2P_GROUP_INTERFACE 0
struct wpa_ssid { bool p2p_group; };
struct wpa_global;
struct wpa_supplicant {
    struct wpa_global *global;
    struct wpa_supplicant *parent, *next, *p2pdev;
    const char *ifname;
    int radio, p2p_group_interface;
    struct wpa_ssid *current_ssid;
    bool nan_mgmt, nan_data;
};
struct wpa_global { struct wpa_supplicant *ifaces; };
static unsigned int disconnects;
static int wpas_p2p_disconnect_safely(struct wpa_supplicant *s,
                                     struct wpa_supplicant *caller)
{
    assert(s && s != caller && s->radio != caller->radio);
    disconnects++;
    return 0;
}
static int wpa_supplicant_remove_iface(struct wpa_global *g,
        struct wpa_supplicant *s, int terminate)
{
    (void)g; (void)s; (void)terminate;
    assert(0); /* These scenarios have no child interfaces. */
    return -1;
}
#include "is-nan.inc"
#include "p2p-group-remove.inc"
#include "deinit-entry.inc"
int main(void)
{
    struct wpa_global g;
    struct wpa_ssid group = { .p2p_group = true };
    struct wpa_supplicant other = {
        .global = &g, .ifname = "wlan1", .radio = 1, .current_ssid = &group
    };
    struct wpa_supplicant removed = {
        .global = &g, .ifname = "nan0", .radio = 0
    };
    other.parent = &other;
    removed.parent = &removed;
    /* Core removal has unlinked the target before entering deinit. Test both
     * a P2P network on a primary interface and a dedicated group interface. */
    g.ifaces = &other;
    for (int dedicated = 0; dedicated <= 1; dedicated++) {
        other.p2p_group_interface = dedicated;
        other.current_ssid = dedicated ? NULL : &group;
        disconnects = 0;
        removed.nan_mgmt = true;
        assert(wpas_is_nan_iface(&removed));
        wpa_supplicant_deinit_iface(&removed, 1, 0);
        assert(disconnects == 0);
        removed.nan_mgmt = false;
        removed.nan_data = true;
        wpa_supplicant_deinit_iface(&removed, 1, 0);
        assert(disconnects == 0);
        /* Preserve the existing cleanup for ordinary root interfaces. */
        removed.nan_data = false;
        wpa_supplicant_deinit_iface(&removed, 1, 0);
        assert(disconnects == 1);
    }
    puts("NAN teardown preserves other-radio P2P; ordinary teardown unchanged");
    return 0;
}
'''


def main():
    source_dir = Path(sys.argv[1]) / 'wpa_supplicant'
    source = (source_dir / 'ctrl_iface.c').read_text()
    start = source.index('static int wpa_supplicant_global_iface_add(')
    end = source.index('\n\nstatic void wpa_free_iface_info(', start)
    status_start = source.index('static int wpas_global_ctrl_iface_status(')
    status_end = source.index('\n\n#ifdef CONFIG_FST', status_start)
    core = (source_dir / 'wpa_supplicant.c').read_text()
    deinit_start = core.index('static void wpa_supplicant_deinit_iface(struct wpa_supplicant *wpa_s,\n')
    deinit_end = core.index('\n\twpa_s->disconnected = 1;', deinit_start)
    # Compile the real cleanup entry and child-removal loop, stopping before
    # unrelated driver/state-machine teardown. Protocol I/O remains stubbed.
    deinit = core[deinit_start:deinit_end] + '\n (void)notify;\n}\n'
    p2p = (source_dir / 'p2p_supplicant.c').read_text()
    p2p_start = p2p.index('int wpas_p2p_group_remove(')
    p2p_end = p2p.index('\n\nstatic int wpas_p2p_select_go_freq', p2p_start)
    header = (source_dir / 'wpa_supplicant_i.h').read_text()
    is_nan_start = header.index('static inline bool wpas_is_nan_iface(')
    is_nan_end = header.index('\n}', is_nan_start) + 2
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / 'interface-add.inc').write_text(source[start:end])
        (root / 'global-status.inc').write_text(source[status_start:status_end])
        (root / 'deinit-entry.inc').write_text(deinit)
        (root / 'p2p-group-remove.inc').write_text(p2p[p2p_start:p2p_end])
        (root / 'is-nan.inc').write_text(header[is_nan_start:is_nan_end])
        for name, harness in [('interface', HARNESS), ('p2p', P2P_HARNESS)]:
            (root / (name + '.c')).write_text(harness)
            subprocess.run([os.environ.get('CC', 'cc'), '-std=c99', '-Wall', '-Wextra',
                            '-Werror', str(root / (name + '.c')), '-o', str(root / name)], check=True)
            subprocess.run([str(root / name)], check=True)


if __name__ == '__main__':
    main()
