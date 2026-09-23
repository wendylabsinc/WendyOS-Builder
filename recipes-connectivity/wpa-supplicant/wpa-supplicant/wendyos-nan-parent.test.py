#!/usr/bin/env python3
"""Exercise the actual patched INTERFACE_ADD parser with two mock radios.

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
#define MACSTR ""
#define MAC2STR(a) 0
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
    struct wpa_supplicant *next;
    unsigned int added_vif;
    void *radio;
};
struct wpa_global { struct wpa_supplicant *ifaces; };
static struct wpa_supplicant wrong, wanted, created;
static struct wpa_supplicant *add_parent, *remove_parent;
static bool fail_register, saw_addr;
static enum wpa_driver_if_type added_type;
static char created_name[32];
static int phy0, phy1;
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
    return 0;
}
#include "interface-add.inc"
static struct wpa_global reset(void)
{
    wanted = (struct wpa_supplicant){ .ifname = "wlan0", .radio = &phy0 };
    wrong = (struct wpa_supplicant){ .ifname = "wlan1", .next = &wanted, .radio = &phy1 };
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
    puts("INTERFACE_ADD/REMOVE explicit radio, NDI parent, rollback and legacy tests passed");
    return 0;
}
'''


def main():
    source = (Path(sys.argv[1]) / 'wpa_supplicant/ctrl_iface.c').read_text()
    start = source.index('static int wpa_supplicant_global_iface_add(')
    end = source.index('\n\nstatic void wpa_free_iface_info(', start)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / 'interface-add.inc').write_text(source[start:end])
        (root / 'test.c').write_text(HARNESS)
        subprocess.run([os.environ.get('CC', 'cc'), '-std=c99', '-Wall', '-Wextra',
                        '-Werror', str(root / 'test.c'), '-o', str(root / 'test')], check=True)
        subprocess.run([str(root / 'test')], check=True)


if __name__ == '__main__':
    main()
