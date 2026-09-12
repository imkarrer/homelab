#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import udr_fw_exporter as exp


class UdrFwExporterTests(unittest.TestCase):
    def test_render_metrics_filters_lan_and_escapes(self) -> None:
        text = exp.render_metrics(
            [
                {"chain": "LAN_IN", "id": "1", "packets": 9},
                {"chain": "WAN_PF_IN", "id": '12"3', "packets": 12},
                {"chain": "WAN_LOCAL", "id": "30001", "packets": 3},
            ]
        )
        self.assertIn(
            'udr_firewall_packets_total{chain="WAN_PF_IN",rule="12\\"3"} 12',
            text,
        )
        self.assertIn(
            'udr_firewall_packets_total{chain="WAN_LOCAL",rule="30001"} 3',
            text,
        )
        self.assertNotIn("LAN_IN", text)


class FakeClient:
    def __init__(self) -> None:
        self.hits: list[dict] = []
        self.fail: Exception | None = None
        self.calls = 0

    def poll(self) -> list[dict]:
        self.calls += 1
        if self.fail:
            raise self.fail
        return self.hits


class PollerTests(unittest.TestCase):
    def test_render_before_first_poll_is_down_but_valid(self) -> None:
        p = exp.Poller(FakeClient(), 300)  # type: ignore[arg-type]
        text = p.render()
        self.assertIn("udr_fw_exporter_up 0\n", text)
        self.assertIn("udr_fw_last_success_timestamp_seconds 0\n", text)
        self.assertNotIn("udr_firewall_packets_total{", text)

    def test_successful_poll_serves_hits_and_up(self) -> None:
        c = FakeClient()
        c.hits = [{"chain": "WAN_PF_IN", "id": "7", "packets": 42}]
        p = exp.Poller(c, 300)  # type: ignore[arg-type]
        p.poll_once(now=1_700_000_000)
        text = p.render()
        self.assertIn('udr_firewall_packets_total{chain="WAN_PF_IN",rule="7"} 42', text)
        self.assertIn("udr_fw_exporter_up 1\n", text)
        self.assertIn("udr_fw_last_success_timestamp_seconds 1700000000\n", text)
        self.assertRegex(text, r"udr_fw_poll_seconds \d+\.\d{3}\n")

    def test_failed_poll_keeps_last_hits_and_reports_down(self) -> None:
        c = FakeClient()
        c.hits = [{"chain": "WAN_LOCAL", "id": "3", "packets": 5}]
        p = exp.Poller(c, 300)  # type: ignore[arg-type]
        p.poll_once(now=100)
        c.fail = TimeoutError("controller slow")
        p.poll_once(now=200)
        text = p.render()
        # Counters are monotonic; the last good value is still the best estimate.
        self.assertIn('udr_firewall_packets_total{chain="WAN_LOCAL",rule="3"} 5', text)
        self.assertIn("udr_fw_exporter_up 0\n", text)
        self.assertIn("udr_fw_last_success_timestamp_seconds 100\n", text)
        self.assertIn("# poll_error TimeoutError\n", text)

    def test_render_does_not_poll(self) -> None:
        c = FakeClient()
        p = exp.Poller(c, 300)  # type: ignore[arg-type]
        for _ in range(5):
            p.render()
        self.assertEqual(c.calls, 0)


if __name__ == "__main__":
    unittest.main()
