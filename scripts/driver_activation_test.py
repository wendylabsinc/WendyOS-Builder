"""Exercise the shipped apply script in an isolated filesystem with mock commands."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
APPLY = ROOT / "recipes-core/wendyos-sysext-apply/files/wendyos-sysext-apply.sh"


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("data/extensions/enabled/test-kernel", "run/extensions",
                     "usr/lib/modules-load.d", "usr/lib/extension-release.d",
                     "usr/lib/wendyos-driver-activation.d",
                     "usr/lib/wendyos-driver-payloads/card/modules/test-kernel",
                     "sys/module/oldwifi",
                     "sys/module/cfg80211", "sys/bus/pci/devices/card", "bin"):
            (self.root / name).mkdir(parents=True)
        (self.root / "data/extensions/enabled/test-kernel/card.raw").touch()
        self.payload = self.root / "usr/lib/wendyos-driver-payloads/card"
        (self.payload / "modules/test-kernel/newwifi.ko").touch()
        (self.payload / "modules-load.conf").write_text("newwifi\n")
        (self.root / "usr/lib/extension-release.d/extension-release.card").write_text(
            "WENDYOS_KERNEL=test-kernel\n")
        (self.root / "sys/bus/pci/devices/card/vendor").write_text("0x8086\n")
        (self.root / "sys/bus/pci/devices/card/device").write_text("0x272b\n")
        self.activation = self.root / "usr/lib/wendyos-driver-activation.d/card.conf"
        self.activation.write_text("pci 8086:272b\nreplace oldwifi\nreplace cfg80211\n"
                                   "reload btusb\nrestart-service wpa_supplicant.service\n")
        source = APPLY.read_text()
        for prefix in ("/data/extensions", "/run/", "/usr/lib/", "/sys/module/",
                       "/sys/bus/pci/devices/", "/sys/class/net/"):
            source = source.replace(prefix, str(self.root) + prefix)
        self.script = self.root / "apply.sh"
        self.script.write_text(source)
        self.log = self.root / "commands.log"
        mock = '''#!/bin/sh
cmd=${0##*/}
printf '%s %s\n' "$cmd" "$*" >> "$TEST_LOG"
case "$cmd" in
    uname) echo test-kernel ;;
    systemd-sysext) [ -z "${REFRESH_HOOK:-}" ] || "$REFRESH_HOOK" ;;
    timeout) shift 2; exec "$@" ;;
    date)
        counter="$TEST_LOG.clock"
        now=100
        [ ! -f "$counter" ] || now=$(cat "$counter")
        echo "$((now + ${CLOCK_STEP:-0}))" > "$counter"
        echo "$now" ;;
    depmod)
        counter="$TEST_LOG.depmod-count"
        n=0
        [ ! -f "$counter" ] || n=$(cat "$counter")
        n=$((n+1)); echo "$n" > "$counter"
        case " ${FAIL_DEPMOD:-} " in *" $n "*) echo "injected depmod failure $n" >&2; exit 1 ;; esac ;;
    nmcli)
        shift 2 # --wait seconds
        case "$*" in
            '-g GENERAL.CON-UUID device show '* )
                [ "${FAIL_CAPTURE:-0}" = 0 ] || exit 1
                printf '%s\\n' "${CONNECTION_UUID-12345678-1234-1234-1234-123456789abc}" ;;
            '-g GENERAL.STATE device show '* )
                if [ "${REDISCOVER_DEVICE:-0}" = 1 ] && [ -e "$TEST_LOG.restore-count" ] && [ ! -e "$TEST_LOG.rediscovered" ]; then
                    touch "$TEST_LOG.rediscovered"; echo '20 (unavailable)'
                else
                    echo '100 (connected)'
                fi ;;
            'connection up '* )
                counter="$TEST_LOG.restore-count"
                n=0; [ ! -f "$counter" ] || n=$(cat "$counter")
                n=$((n+1)); echo "$n" > "$counter"
                case " ${FAIL_RESTORE:-} " in *" $n "*) exit 1 ;; esac ;;
        esac ;;
    systemctl)
        if [ "${FAIL_SERVICE:-0}" != 0 ] && [ ! -e "$TEST_LOG.service-failed" ]; then
            touch "$TEST_LOG.service-failed"; exit 1
        fi ;;
    rmmod) [ "${2:-}" != "${FAIL_UNLOAD:-}" ] || exit 1 ;;
    modprobe)
        if [ "${1:-}" = -- ] && [ "${2:-}" = oldwifi ] && [ -n "${REQUIRE_OLD_MODULE:-}" ]; then
            [ "$(cat "$REQUIRE_OLD_MODULE" 2>/dev/null)" = old-module ] || exit 1
        fi
        if [ "${1:-}" = -r ] && [ "${3:-}" = "${UNINDEXED_MODULE:-}" ]; then
            echo "Module ${3} not found" >&2; exit 1
        fi
        if [ "${1:-}" = -- ] && [ "${2:-}" = "${SIGNAL_ON_LOAD:-}" ]; then
            kill -"${TEST_SIGNAL:-TERM}" "$PPID"
            exit 1
        fi
        if [ "${1:-}" = -r ] && [ "${3:-}" = "${FAIL_UNLOAD:-}" ]; then
            exit 1
        fi
        if [ "${1:-}" = -- ] && [ "${2:-}" = "${FAIL_LOAD:-}" ]; then
            exit 1
        fi ;;
esac
exit 0
'''
        for name in ("uname", "systemd-sysext", "depmod", "udevadm", "modprobe",
                     "systemctl", "timeout", "nmcli", "date", "sleep", "rmmod"):
            path = self.root / "bin" / name
            path.write_text(mock)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                        TEST_LOG=str(self.log), WENDYOS_SYSEXT_APPLY_LOCKED="1")

    def run_apply(self, subject="card"):
        result = subprocess.run(["sh", str(self.script), subject], env=self.env,
                                capture_output=True, text=True, check=False)
        calls = self.log.read_text().splitlines()
        return result, calls

    def previous_payload(self):
        previous = self.root / "previous-payload"
        self.payload.rename(previous)
        self.payload.mkdir()
        (self.payload / "modules/test-kernel").mkdir(parents=True)
        (self.payload / "modules/test-kernel/oldwifi.ko").write_text("old-module")
        (self.payload / "modules-load.conf").write_text("oldwifi\n")
        (self.payload / "firmware").mkdir()
        (self.payload / "firmware/card.bin").write_text("old-firmware")
        exposed = self.root / "usr/lib/modules/test-kernel/updates/wendyos/card"
        exposed.mkdir(parents=True)
        old_module = exposed / "oldwifi.ko"
        old_module.symlink_to(self.payload / "modules/test-kernel/oldwifi.ko")
        firmware = self.root / "usr/lib/firmware/card.bin"
        firmware.parent.mkdir(parents=True)
        firmware.symlink_to(self.payload / "firmware/card.bin")
        hook = self.root / "refresh"
        hook.write_text(f"#!/bin/sh\nrm -rf '{exposed}' '{firmware}' '{self.payload}'\n"
                        f"cp -R '{previous}' '{self.payload}'\n"
                        f"rm -rf '{self.root}/usr/lib/wendyos-driver-state'\n")
        hook.chmod(0o755)
        self.env.update(REFRESH_HOOK=str(hook), REQUIRE_OLD_MODULE=str(old_module))
        return old_module, firmware

    def test_real_files_survive_refresh_and_repeated_failed_activation(self):
        old_module, firmware = self.previous_payload()
        self.env["FAIL_SERVICE"] = "1"
        for attempt in range(2):
            (self.root / "commands.log.service-failed").unlink(missing_ok=True)
            result, calls = self.run_apply()
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn("activation rolled back", result.stderr)
            self.assertNotIn("rollback incomplete", result.stderr)
            self.assertEqual(old_module.read_text(), "old-module")
            self.assertEqual(firmware.read_text(), "old-firmware")
            self.assertFalse(old_module.is_symlink())
            self.assertEqual(list((self.root / "run").glob("wendyos-driver-plan.*")), [])
            state = self.root / "usr/lib/wendyos-driver-state/card/modules-load.conf"
            self.assertEqual(state.read_text(), "oldwifi\n")

    def test_rolled_back_owner_still_blocks_a_later_conflicting_package(self):
        self.previous_payload()
        (self.root / "data/extensions/enabled/test-kernel/zeta.raw").touch()
        zeta = self.root / "usr/lib/wendyos-driver-payloads/zeta/modules/test-kernel"
        zeta.mkdir(parents=True)
        (zeta / "oldwifi.ko").write_text("conflicting-module")
        self.env["FAIL_SERVICE"] = "1"
        result, _ = self.run_apply("")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("zeta conflicts with earlier package card", result.stderr)
        self.assertFalse((self.root / "usr/lib/modules/test-kernel/updates/wendyos/zeta/oldwifi.ko").exists())

    def test_capture_failure_preserves_old_exposure_after_refresh(self):
        self.with_wifi()
        old_module, firmware = self.previous_payload()
        self.env["FAIL_CAPTURE"] = "1"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c.startswith("rmmod") for c in calls))
        self.assertEqual(old_module.read_text(), "old-module")
        self.assertEqual(firmware.read_text(), "old-firmware")

    def test_initial_depmod_failure_preserves_old_exposure(self):
        old_module, firmware = self.previous_payload()
        self.env["FAIL_DEPMOD"] = "1"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c.startswith("rmmod") for c in calls))
        self.assertEqual(old_module.read_text(), "old-module")
        self.assertEqual(firmware.read_text(), "old-firmware")

    def test_incomplete_snapshot_refuses_refresh(self):
        old_module, _ = self.previous_payload()
        state = self.root / "usr/lib/wendyos-driver-state/card"
        state.mkdir(parents=True)
        (state / "files").write_text(str(old_module) + ".missing\n")
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing refresh", result.stderr)
        self.assertFalse(any(c.startswith("systemd-sysext") for c in calls))
        self.assertEqual(old_module.read_text(), "old-module")

    def test_success_records_private_metadata_and_replacement_receipt(self):
        old_module, _ = self.previous_payload()
        result, _ = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old_module.exists())
        state = self.root / "usr/lib/wendyos-driver-state/card"
        self.assertEqual((state / "modules-load.conf").read_text(), "newwifi\n")
        self.assertIn("oldwifi", (state / "replaced-modules").read_text())
        self.assertTrue((state / "generation").read_text().strip())

    def test_replacement_order(self):
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        operations = [line for line in calls if line.startswith(("rmmod", "modprobe -r", "modprobe -- ", "systemctl"))]
        self.assertEqual(operations, ["rmmod -- oldwifi", "rmmod -- cfg80211",
                                     "modprobe -- newwifi", "modprobe -- btusb",
                                     "systemctl try-restart -- wpa_supplicant.service"])

    def test_loaded_addon_can_unload_after_refresh_removes_its_index_entry(self):
        self.env["UNINDEXED_MODULE"] = "oldwifi"
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rmmod -- oldwifi", calls)
        self.assertNotIn("modprobe -r -- oldwifi", calls)
        self.assertIn("modprobe -- newwifi", calls)

    def test_explicit_install_fails_on_absent_hardware(self):
        (self.root / "sys/bus/pci/devices/card/device").write_text("0x1234\n")
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith(("modprobe", "systemctl")) for line in calls))
        self.assertFalse((self.root / "usr/lib/modules/test-kernel/updates/wendyos/card").exists())

    def test_unrelated_install_does_not_reload(self):
        result, calls = self.run_apply("other")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(line.startswith(("rmmod", "modprobe -r", "systemctl")) for line in calls))

    def test_unload_failure_does_not_insert_mixed_stack(self):
        self.env["FAIL_UNLOAD"] = "cfg80211"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("prior modules restored", result.stderr)
        self.assertIn("modprobe -- oldwifi", calls)
        self.assertNotIn("modprobe -- newwifi", calls)
        self.assertIn("systemctl try-restart -- wpa_supplicant.service", calls)

    def test_load_failure_unexposes_payload_and_restores_old_stack(self):
        (self.payload / "firmware").mkdir()
        (self.payload / "firmware/card.bin").write_text("replacement")
        firmware = self.root / "usr/lib/firmware/card.bin"
        firmware.parent.mkdir(parents=True)
        firmware.write_text("base")
        self.env["FAIL_LOAD"] = "btusb"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("activation rolled back", result.stderr)
        self.assertIn("modprobe -r -- newwifi", calls)
        self.assertLess(calls.index("modprobe -- cfg80211"), calls.index("modprobe -- oldwifi"))
        self.assertFalse((self.root / "usr/lib/modules/test-kernel/updates/wendyos/card/newwifi.ko").exists())
        self.assertEqual(firmware.read_text(), "base")

    def test_external_holder_blocks_replacement_before_unload(self):
        holders = self.root / "sys/module/cfg80211/holders"
        holders.mkdir()
        (holders / "unexpected").touch()
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected depends on it", result.stderr)
        self.assertFalse(any(line.startswith(("rmmod", "modprobe -r")) for line in calls))

    def test_failed_rollback_reports_reboot_requirement(self):
        self.env["FAIL_LOAD"] = "btusb"
        self.env["FAIL_UNLOAD"] = "newwifi"
        result, _ = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rollback incomplete", result.stderr)
        self.assertIn("reboot required", result.stderr)

    def test_malformed_metadata_fails_before_module_changes(self):
        self.activation.write_text("replace invalid module\n")
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith(("modprobe", "systemctl")) for line in calls))

    def test_legacy_addon_loads_without_activation_metadata(self):
        self.activation.unlink()
        (self.root / "usr/lib/modules-load.d/card.conf").write_text("newwifi\n")
        for child in sorted(self.payload.rglob("*"), reverse=True):
            child.unlink() if child.is_file() else child.rmdir()
        self.payload.rmdir()
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("modprobe -- newwifi", calls)
        self.assertFalse(any(line.startswith(("rmmod", "modprobe -r", "systemctl")) for line in calls))

    def test_alphabetically_first_payload_wins_module_collision(self):
        (self.root / "data/extensions/enabled/test-kernel/zeta.raw").touch()
        zeta = self.root / "usr/lib/wendyos-driver-payloads/zeta"
        (zeta / "modules/test-kernel").mkdir(parents=True)
        (zeta / "modules/test-kernel/newwifi.ko").touch()
        (zeta / "modules-load.conf").write_text("newwifi\n")
        result, calls = self.run_apply("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("zeta conflicts with earlier package card", result.stderr)
        self.assertTrue((self.root / "usr/lib/modules/test-kernel/updates/wendyos/card/newwifi.ko").is_symlink())
        self.assertFalse((self.root / "usr/lib/modules/test-kernel/updates/wendyos/zeta").exists())
        self.assertEqual(calls.count("modprobe -- newwifi"), 1)

    def test_dash_and_underscore_module_names_collide(self):
        (self.payload / "modules/test-kernel/newwifi.ko").unlink()
        (self.payload / "modules/test-kernel/shared-name.ko").touch()
        (self.root / "data/extensions/enabled/test-kernel/zeta.raw").touch()
        zeta = self.root / "usr/lib/wendyos-driver-payloads/zeta/modules/test-kernel"
        zeta.mkdir(parents=True)
        (zeta / "shared_name.ko").touch()
        result, _ = self.run_apply("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("module:shared_name", result.stderr)

    def test_ineligible_earlier_payload_does_not_reserve_claims(self):
        (self.root / "sys/bus/pci/devices/card/device").write_text("0x1234\n")
        (self.root / "data/extensions/enabled/test-kernel/zeta.raw").touch()
        zeta = self.root / "usr/lib/wendyos-driver-payloads/zeta"
        (zeta / "modules/test-kernel").mkdir(parents=True)
        (zeta / "modules/test-kernel/newwifi.ko").touch()
        (zeta / "modules-load.conf").write_text("newwifi\n")
        result, calls = self.run_apply("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("modprobe -- newwifi", calls)
        self.assertTrue((self.root / "usr/lib/modules/test-kernel/updates/wendyos/zeta/newwifi.ko").is_symlink())

    def with_wifi(self):
        (self.root / "sys/class/net/wlan0").mkdir(parents=True, exist_ok=True)
        self.activation.write_text(self.activation.read_text() + "restore-wifi-connection wlan0\n")

    def restores(self, calls):
        return [c for c in calls if c.startswith("nmcli --wait") and " connection up " in c]

    def test_boot_skips_absent_hardware(self):
        (self.root / "sys/bus/pci/devices/card/device").write_text("0x1234\n")
        result, calls = self.run_apply("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c.startswith("modprobe") for c in calls))

    def test_explicit_install_fails_on_collision(self):
        (self.root / "data/extensions/enabled/test-kernel/zeta.raw").touch()
        zeta = self.root / "usr/lib/wendyos-driver-payloads/zeta/modules/test-kernel"
        zeta.mkdir(parents=True)
        (zeta / "newwifi.ko").touch()
        result, _ = self.run_apply("zeta")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("zeta conflicts with earlier package card", result.stderr)

    def test_wifi_restored_after_partial_unload_failure(self):
        self.with_wifi()
        self.env["FAIL_UNLOAD"] = "cfg80211"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.restores(calls)), 1)
        self.assertLess(calls.index("modprobe -- oldwifi"), calls.index(self.restores(calls)[0]))
        self.assertIn("prior modules restored", result.stderr)

    def test_wifi_restored_after_payload_index_failure(self):
        self.with_wifi()
        self.env["FAIL_DEPMOD"] = "2"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.restores(calls)), 1)
        self.assertIn("activation rolled back", result.stderr)
        self.assertFalse((self.root / "usr/lib/modules/test-kernel/updates/wendyos/card/newwifi.ko").exists())

    def test_wifi_restored_after_module_load_failure(self):
        self.with_wifi()
        self.env["FAIL_LOAD"] = "btusb"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.restores(calls)), 1)
        self.assertLess(calls.index("modprobe -- oldwifi"), calls.index(self.restores(calls)[0]))

    def test_failed_capture_prevents_unload(self):
        self.with_wifi()
        self.env["FAIL_CAPTURE"] = "1"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot capture wlan0", result.stderr)
        self.assertFalse(any(c.startswith(("rmmod", "modprobe -r")) for c in calls))

    def test_first_install_without_interface_needs_no_capture(self):
        self.with_wifi()
        (self.root / "sys/class/net/wlan0").rmdir()
        self.env["FAIL_CAPTURE"] = "1"
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c.startswith("nmcli") for c in calls))

    def test_disconnected_interface_needs_no_restoration(self):
        self.with_wifi()
        self.env["CONNECTION_UUID"] = "--"
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.restores(calls), [])

    def test_failed_reconnect_rolls_back_and_restores_old_connection(self):
        self.with_wifi()
        self.env["FAIL_RESTORE"] = "1"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.restores(calls)), 2)
        self.assertIn("modprobe -- oldwifi", calls)
        self.assertIn("activation rolled back", result.stderr)

    def test_reconnect_retries_when_nm_rediscovers_recreated_device(self):
        self.with_wifi()
        self.env.update(FAIL_RESTORE="1", REDISCOVER_DEVICE="1")
        result, calls = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.restores(calls)), 2)
        self.assertNotIn("modprobe -- oldwifi", calls)

    def test_failed_reconnect_during_rollback_reports_incomplete(self):
        self.with_wifi()
        self.env.update(FAIL_LOAD="btusb", FAIL_RESTORE="1")
        result, _ = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rollback incomplete", result.stderr)
        self.assertNotIn("activation rolled back", result.stderr)

    def test_wifi_deadline_exhaustion_is_failure(self):
        self.with_wifi()
        self.env["CLOCK_STEP"] = "30"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not restore wlan0", result.stderr)
        self.assertEqual(self.restores(calls), [])

    def test_both_rollback_paths_report_depmod_failure(self):
        for cause in ("expose", "load"):
            with self.subTest(cause=cause):
                counter = self.root / "commands.log.depmod-count"
                counter.unlink(missing_ok=True)
                self.env["FAIL_DEPMOD"] = "2 3" if cause == "expose" else "3"
                self.env["FAIL_LOAD"] = "btusb" if cause == "load" else ""
                result, calls = self.run_apply()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("injected depmod failure 3", result.stderr)
                self.assertIn("could not rebuild module index during rollback", result.stderr)
                self.assertIn("rollback incomplete", result.stderr)
                self.assertNotIn("activation rolled back", result.stderr)
                self.assertIn("modprobe -- oldwifi", calls)

    def test_signals_exit_without_claiming_rollback(self):
        for signal, status in (("HUP", 129), ("INT", 130), ("TERM", 143)):
            with self.subTest(signal=signal):
                self.env.update(SIGNAL_ON_LOAD="btusb", TEST_SIGNAL=signal)
                result, _ = self.run_apply()
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn("interrupted", result.stderr)
                self.assertIn("reboot required", result.stderr)
                self.assertNotIn("activation rolled back", result.stderr)
                self.assertEqual(list((self.root / "run").glob("wendyos-driver-plan.*")), [])

    def test_option_shaped_service_is_rejected(self):
        self.activation.write_text("restart-service --help\n")
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("malformed activation metadata", result.stderr)
        self.assertFalse(any(c.startswith("systemctl") for c in calls))

    def test_service_failure_restores_wifi_during_rollback(self):
        self.with_wifi()
        self.env["FAIL_SERVICE"] = "1"
        result, calls = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("modprobe -- oldwifi", calls)
        self.assertEqual(len(self.restores(calls)), 1)


if __name__ == "__main__":
    unittest.main()
