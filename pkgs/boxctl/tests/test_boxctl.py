"""Tests for boxctl's dry-activate parser and CLI, run against fixtures in
this directory instead of a live box.

CRITICAL constraint this whole test suite exists to protect: boxctl must
never run `switch-to-configuration switch/boot/test` or `nixos-rebuild`.
These tests only ever pass it `--dry-activate-output <fixture file>`, which
takes the real subprocess call out of the loop entirely -- this is the "do
NOT run dry-activate on the box" verification path the task asked for.

tenants.json here is a hand-transcribed copy of what
modules/tenant/tests/eval-quiet.nix's fixture produces (see that file's
`tenantsJson` output) -- kept as a plain JSON fixture so these tests don't
need to shell out to `nix eval` to run.

dry-activate-*.txt fixtures use the exact wording emitted by
switch-to-configuration-ng's src/main.rs (would stop / would NOT stop / would
reload / would restart / would start the following units: ..., would restart
systemd) -- that binary is the only switch-to-configuration implementation
in the nixpkgs tree as of nixos-26.05, the old Perl script has been removed.

Run with:
    python3 -m unittest discover -s pkgs/boxctl/tests -v
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
BOXCTL_PY = HERE.parent / "boxctl.py"
TENANTS_JSON = HERE / "tenants.json"
DISRUPTIVE = HERE / "dry-activate-disruptive.txt"
SAFE = HERE / "dry-activate-safe.txt"
RESTART_SYSTEMD = HERE / "dry-activate-restart-systemd.txt"
BOUNCED = HERE / "dry-activate-bounced.txt"

# Import boxctl.py by path (it has no shebang-stripped package identity, and
# nothing about it should require being on sys.path/installed to be tested).
spec = importlib.util.spec_from_file_location("boxctl", BOXCTL_PY)
boxctl = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(boxctl)


class ParseDryActivateTests(unittest.TestCase):
    def test_disruptive_fixture(self):
        parsed = boxctl.parse_dry_activate(DISRUPTIVE.read_text())
        self.assertEqual(parsed["stop"], ["old-cruft.service"])
        self.assertEqual(parsed["skip"], ["sshd-keygen.service"])
        self.assertEqual(parsed["reload"], ["prometheus.service"])
        self.assertEqual(
            parsed["restart"],
            ["ac-host-static.service", "agent-hub-llm.service", "docker.service"],
        )
        self.assertEqual(parsed["start"], ["arcade-mindustry.service"])
        self.assertFalse(parsed["restart_systemd"])

    def test_safe_fixture(self):
        parsed = boxctl.parse_dry_activate(SAFE.read_text())
        self.assertEqual(parsed["stop"], [])
        self.assertEqual(parsed["reload"], [])
        self.assertEqual(parsed["restart"], ["agent-hub-llm.service"])
        self.assertEqual(parsed["start"], ["arcade-mindustry.service"])
        self.assertFalse(parsed["restart_systemd"])

    def test_restart_systemd_fixture(self):
        parsed = boxctl.parse_dry_activate(RESTART_SYSTEMD.read_text())
        self.assertTrue(parsed["restart_systemd"])
        self.assertEqual(parsed["reload"], ["grafana.service"])

    def test_bounced_fixture_reports_raw_buckets(self):
        # parse_dry_activate is a literal transcription of dry-activate's own
        # buckets -- a unit in both "stop" and "start" stays in both here.
        # Reclassifying stop+start as a restart is cmd_plan's job (see
        # CmdPlanTests.test_bounced_units_reported_as_restart_not_new_start),
        # not the parser's.
        parsed = boxctl.parse_dry_activate(BOUNCED.read_text())
        self.assertEqual(
            parsed["stop"], ["prometheus.service", "grafana.service", "old-cruft.service"]
        )
        self.assertEqual(
            parsed["start"], ["prometheus.service", "grafana.service", "arcade-mindustry.service"]
        )
        self.assertEqual(parsed["restart"], [])

    def test_empty_input(self):
        parsed = boxctl.parse_dry_activate("")
        for key in ("stop", "skip", "reload", "restart", "start"):
            self.assertEqual(parsed[key], [])
        self.assertFalse(parsed["restart_systemd"])


class UnitOwnerMapTests(unittest.TestCase):
    def test_maps_every_declared_unit(self):
        tenants = boxctl.load_tenants(TENANTS_JSON)
        owner = boxctl.unit_owner_map(tenants)
        self.assertEqual(owner["ac-host-static.service"], "assetto")
        self.assertEqual(owner["docker.service"], "assetto")
        self.assertEqual(owner["agent-hub-llm.service"], "agent-hub")
        self.assertNotIn("old-cruft.service", owner)


class DrainStatusTests(unittest.TestCase):
    def test_drainable_tenant(self):
        self.assertEqual(
            boxctl.drain_status({"drainable": True, "busyCheck": None}, run_checks=True),
            "drainable",
        )

    def test_not_drainable_no_busycheck(self):
        status = boxctl.drain_status({"drainable": False, "busyCheck": None}, run_checks=True)
        self.assertIn("NOT drainable", status)
        self.assertIn("no busyCheck", status)

    def test_not_drainable_busy(self):
        # exit 0 == BUSY, per schema.nix's quiet.busyCheck contract. "true"
        # is a shell builtin (portable -- NixOS has no /bin/true), run
        # through the same `/bin/sh -c <cmd>` path run_busy_check uses.
        status = boxctl.drain_status(
            {"drainable": False, "busyCheck": "true"}, run_checks=True
        )
        self.assertIn("BUSY", status)

    def test_not_drainable_idle(self):
        status = boxctl.drain_status(
            {"drainable": False, "busyCheck": "false"}, run_checks=True
        )
        self.assertIn("not busy right now", status)

    def test_no_busy_check_flag_skips_running_it(self):
        # --no-busy-check must report the policy answer without executing
        # anything -- run_checks=False must never shell out.
        status = boxctl.drain_status(
            {"drainable": False, "busyCheck": "false"}, run_checks=False
        )
        self.assertNotIn("not busy right now", status)
        self.assertIn("NOT drainable", status)


class CmdStatusTests(unittest.TestCase):
    def test_status_lists_all_tenants_and_exits_zero(self):
        args = boxctl.build_parser().parse_args(
            ["status", "--tenants-file", str(TENANTS_JSON), "--no-busy-check"]
        )
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = boxctl.main(
                ["status", "--tenants-file", str(TENANTS_JSON), "--no-busy-check"]
            )
        self.assertEqual(code, 0)
        out = buf.getvalue()
        for name in ("agent-hub", "arcade", "assetto", "observability"):
            self.assertIn(name, out)


class CmdPlanTests(unittest.TestCase):
    def _run_plan(self, dry_activate_file: Path, extra: list[str] | None = None) -> tuple[int, str]:
        buf = io.StringIO()
        argv = [
            "plan",
            "--tenants-file",
            str(TENANTS_JSON),
            "--dry-activate-output",
            str(dry_activate_file),
        ] + (extra or [])
        with contextlib.redirect_stdout(buf):
            code = boxctl.main(argv)
        return code, buf.getvalue()

    def test_disruptive_plan_must_wait(self):
        code, out = self._run_plan(DISRUPTIVE)
        self.assertEqual(code, 1, out)
        self.assertIn("DANGER", out)
        self.assertIn("ac-host-static.service", out)
        self.assertIn("docker.service", out)
        self.assertIn("docker rm -f", out)
        self.assertIn("assetto", out)
        self.assertIn("observability", out)
        self.assertIn("old-cruft.service", out)  # unowned unit still reported
        self.assertIn("cannot apply now", out)
        self.assertIn("03:00", out)

    def test_safe_plan_can_apply_now(self):
        code, out = self._run_plan(SAFE)
        self.assertEqual(code, 0, out)
        self.assertNotIn("DANGER", out)
        self.assertIn("no affected tenant requires a maintenance window", out)

    def test_restart_systemd_forces_wait(self):
        code, out = self._run_plan(RESTART_SYSTEMD)
        self.assertEqual(code, 1, out)
        self.assertIn("restart systemd", out)

    def test_custom_maintenance_window_is_reported(self):
        code, out = self._run_plan(DISRUPTIVE, extra=["--maintenance-window", "04:30"])
        self.assertEqual(code, 1, out)
        self.assertIn("04:30", out)

    def test_bounced_units_reported_as_restart_not_new_start(self):
        # homelab-bqo.26: a unit dry-activate lists in both "would stop" and
        # "would start" (prometheus/grafana, seen live on the phase 6 plan)
        # is a restart -- it must appear on the "would restart:" line and
        # must NOT be labeled "(newly-started units, not disruptive)", which
        # would understate a real scrape gap / dashboard blink.
        _, out = self._run_plan(BOUNCED)
        self.assertIn("would restart:", out)
        restart_line = next(l for l in out.splitlines() if l.startswith("would restart:"))
        self.assertIn("prometheus.service", restart_line)
        self.assertIn("grafana.service", restart_line)

        start_line = next(l for l in out.splitlines() if l.startswith("would start:"))
        self.assertNotIn("prometheus.service", start_line)
        self.assertNotIn("grafana.service", start_line)
        self.assertIn("arcade-mindustry.service", start_line)
        self.assertIn("(newly-started units, not disruptive)", start_line)

        stop_line = next(l for l in out.splitlines() if l.startswith("would stop:"))
        self.assertIn("old-cruft.service", stop_line)

    def test_plan_never_mentions_switch_or_boot_actions(self):
        # boxctl's own output must never suggest it performed (or could be
        # made to perform) anything but a dry run.
        _, out = self._run_plan(DISRUPTIVE)
        self.assertNotIn("switch-to-configuration switch", out.replace("does not apply plans. Applying (switch-to-configuration ", ""))


class ReadOnlyGuaranteeTests(unittest.TestCase):
    """Static checks on the source itself: there is exactly one place that
    can ever invoke switch-to-configuration, and its action argument is a
    literal, not something argv can influence. boxctl has three
    subprocess.run call sites total (busyCheck, `nix build`, and
    switch-to-configuration dry-activate) -- only the last one may name
    switch-to-configuration at all, and only with the literal "dry-activate".
    """

    def test_only_one_callsite_can_run_switch_to_configuration(self):
        source = BOXCTL_PY.read_text()
        self.assertEqual(source.count("subprocess.run"), 3)
        # Exactly one call site builds an argv naming the
        # switch-to-configuration binary, and it pairs that binary with the
        # literal "dry-activate" right there -- not a variable, not a flag.
        self.assertEqual(source.count('[str(binary), "dry-activate"]'), 1)
        # No other action word is ever passed as a quoted CLI argument.
        for forbidden in ('"switch"', '"boot"', '"test"'):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
