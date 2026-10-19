#!/usr/bin/env python3
"""Run actual peer-removal/disconnect bodies against counted NDI references.

Usage: python3 wendyos-nan-peer.test.py /path/to/patched/wpa_supplicant-2.12
The radio, timers and unrelated peer resources are stubbed; list operations and
production teardown/callback bodies are real. No hardware is accessed.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def function(source, name):
    match = re.search(r'(?:static )?(?:void|bool) ' + name + r'\([^;]*?\)\s*\{', source)
    if not match:
        raise ValueError(f'missing function {name}')
    end, depth = match.end(), 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]


HARNESS = r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "list.h"
typedef unsigned char u8;
#define ETH_ALEN 6
#define os_memset memset
#define os_memcpy memcpy
#define os_free free
#define wpa_printf(...) ((void)0)
#define ether_addr_equal(a,b) (!memcmp(a,b,ETH_ALEN))
enum nan_reason { NAN_REASON_UNSPECIFIED_REASON };
struct nan_ndp_id { u8 peer_nmi[6], init_ndi[6], id; };
struct nan_ndp { struct dl_list list; bool initiator, connected; u8 init_ndi[6], resp_ndi[6], ndp_id, gtk_id; };
struct nan_peer {
    struct dl_list list, ndps;
    u8 nmi_addr[6];
    struct { struct nan_ndp *ndp; int state; } ndp_setup;
    struct { void *npba; } bootstrap;
    int info;
};
struct nan_config {
    void *cb_ctx;
    void (*ndp_disconnected)(void *, struct nan_ndp_id *, const u8 *, const u8 *,
                            enum nan_reason, bool, bool, bool, u8);
};
struct nan_data { struct nan_config *cfg; };
struct wpa_supplicant { int unused; };
static unsigned int notifications, failures, releases, station_removals, sec_removals, setups_freed;
static unsigned int seen;
static void wpas_nan_remove_ndi_sta(struct wpa_supplicant *s, const u8 *local,
                                   const u8 *peer, bool remove, u8 gtk) {
    (void)s; (void)gtk;
    assert(local[0] == 2 && peer[0] == 3);
    releases++;
    station_removals += remove;
}
static void wpas_notify_nan_ndp_disconnected(struct wpa_supplicant *s, const u8 *peer,
        u8 id, const u8 *local, const u8 *remote, enum nan_reason reason, bool locally_generated, bool failure) {
    (void)s; (void)peer; (void)reason;
    assert(local[0] == 2 && remote[0] == 3 && locally_generated);
    assert(!(seen & (1u << id)));
    seen |= 1u << id;
    notifications++;
    failures += failure;
}
#define wpabuf_free(p) free(p)
#define nan_bootstrap_reset(n,p) ((void)0)
#define nan_peer_flush_avail(p) ((void)0)
#define nan_peer_flush_ulw(p) ((void)0)
#define nan_peer_flush_dev_capa(p) ((void)0)
#define nan_peer_flush_elem_container(p) ((void)0)
#define nan_remove_group_keys(n,p) ((void)0)
#define nan_ndl_reset(n,p) ((void)0)
#define nan_peer_flush_sec(p) ((void)0)
#define eloop_cancel_timeout(...) ((void)0)
#define nan_pairing_deinit_peer(p) ((void)0)
static void nan_peer_del_sec_entry(int *info, const u8 *peer) {
    (void)info; assert(peer[0] == 3); sec_removals++;
}
static void nan_ndp_setup_stop(struct nan_data *nan, struct nan_peer *peer) {
    (void)nan;
    assert(peer->ndp_setup.ndp);
    free(peer->ndp_setup.ndp);
    peer->ndp_setup.ndp = NULL;
    peer->ndp_setup.state = 0;
    setups_freed++;
}
#include "production.inc"
static struct nan_ndp *ndp(u8 id, bool connected, bool initiator) {
    struct nan_ndp *p = calloc(1, sizeof(*p)); assert(p);
    p->ndp_id = id; p->connected = connected; p->initiator = initiator;
    p->init_ndi[0] = initiator ? 2 : 3;
    p->resp_ndi[0] = initiator ? 3 : 2;
    return p;
}
int main(void) {
    struct wpa_supplicant supplicant;
    struct nan_config cfg = { &supplicant, wpas_nan_ndp_disconnected_cb };
    struct nan_data nan = { &cfg };
    for (int pending = 0; pending <= 1; pending++) {
        for (int connected = 0; connected <= 2; connected++) {
            struct dl_list peers; dl_list_init(&peers);
            struct nan_peer *peer = calloc(1, sizeof(*peer)); assert(peer);
            dl_list_init(&peer->ndps); dl_list_add(&peers, &peer->list);
            notifications = failures = releases = station_removals = sec_removals = setups_freed = seen = 0;
            for (int i = 0; i < connected; i++) {
                struct nan_ndp *p = ndp(i + 1, true, i == 0);
                dl_list_add(&peer->ndps, &p->list);
            }
            if (pending) peer->ndp_setup.ndp = ndp(3, false, false);
            /* Transaction state cannot stand in for NDP reference ownership. */
            peer->ndp_setup.state = 7;
            nan_del_peer(&nan, peer);
            assert(dl_list_empty(&peers));
            assert(notifications == (unsigned)(pending + connected));
            assert(setups_freed == notifications);
            assert(failures == (unsigned)pending);
            assert(releases == (unsigned)connected);
            assert(station_removals == (unsigned)(connected != 0));
            assert(sec_removals == (unsigned)(pending || connected));
        }
    }
    nan_del_peer(&nan, NULL);
    puts("Peer disappearance: established/pending/shared-NDI references and callbacks PASS (6 cases)");
}
'''


def main():
    source = Path(sys.argv[1])
    nan = (source / 'src/nan/nan.c').read_text()
    supplicant = (source / 'wpa_supplicant/nan_supplicant.c').read_text()
    bodies = [function(supplicant, 'wpas_nan_ndp_disconnected_cb')]
    bodies += [function(nan, name) for name in ('nan_peer_ndi_in_use', 'nan_ndp_disconnected', 'nan_del_peer')]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / 'production.inc').write_text('\n\n'.join(bodies))
        (root / 'peer.c').write_text(HARNESS)
        subprocess.run([os.environ.get('CC', 'cc'), '-std=c99', '-Wall', '-Wextra', '-Werror',
                        '-I', str(source / 'src/utils'), str(root / 'peer.c'), '-o', str(root / 'peer')], check=True)
        subprocess.run([str(root / 'peer')], check=True)


if __name__ == '__main__':
    main()
