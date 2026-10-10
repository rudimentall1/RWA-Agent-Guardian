"""Offline unit tests for the AI benchmark harness. No Ollama calls are made."""
import json
from contextlib import ExitStack
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ai_benchmark


class AIBenchmarkTests(unittest.TestCase):
    def test_scenario_matrix_covers_four_distinct_policy_states(self):
        now = 1_900_000_000
        cases = [
            ai_benchmark.scenario("accepted_active_with_capacity", 2, True, now + 3600, 2000),
            ai_benchmark.scenario("unaccepted_invoice", 1, True, now + 3600, 2000),
            ai_benchmark.scenario("inactive_mandate", 2, False, now - 1, 2000),
            ai_benchmark.scenario("zero_capacity", 2, True, now + 3600, 0),
        ]
        self.assertEqual(len(cases), 4)
        self.assertEqual(len({case["name"] for case in cases}), 4)
        self.assertEqual(cases[1]["context"]["invoice"]["status"], 1)
        self.assertFalse(cases[2]["context"]["mandate"]["active"])
        self.assertEqual(cases[3]["context"]["maxAllowedAmount"], 0)

    def test_main_records_gate_rejection_and_never_claims_a_transaction(self):
        proposals = [
            {"decision": "ALLOW", "amount": 2000, "reason": "within_limits"},
            {"decision": "ALLOW", "amount": 2000, "reason": "within_limits"},
            {"decision": "BLOCK", "amount": 0, "reason": "invoice_not_accepted"},
            {"decision": "BLOCK", "amount": 0, "reason": "invoice_not_accepted"},
        ]

        def fake_reason(context, proposal):
            if context["invoice"]["status"] == 1:
                raise SystemExit("AI ALLOW does not match the checked policy facts; no transaction sent")
            if not context["mandate"]["active"] or context["maxAllowedAmount"] == 0:
                raise SystemExit("AI reason code contradicts the decision or checked policy facts; no transaction sent")
            return "Within current on-chain caps"

        with tempfile.TemporaryDirectory() as tmp:
            output = str(Path(tmp) / "benchmark.json")
            argv = ["ai_benchmark.py", "--output", output]
            with patch.object(sys, "argv", argv), \
                 patch.object(ai_benchmark, "ask_ollama", side_effect=proposals) as ask, \
                 patch.object(ai_benchmark, "canonical_decision_reason", side_effect=fake_reason):
                self.assertEqual(ai_benchmark.main(), 0)

            report = json.loads(Path(output).read_text(encoding="utf-8"))
            self.assertEqual(ask.call_count, 4)
            self.assertEqual(report["transactionsSent"], 0)
            self.assertEqual(report["cases"], 4)
            self.assertEqual(report["gatePasses"], 1)
            self.assertEqual(report["gateBlocks"], 3)
            self.assertEqual([r["gate"] for r in report["results"]], ["PASS", "BLOCK", "BLOCK", "BLOCK"])

    def test_inference_exception_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = str(Path(tmp) / "benchmark.json")
            argv = ["ai_benchmark.py", "--output", output]
            with patch.object(sys, "argv", argv), \
                 patch.object(ai_benchmark, "ask_ollama", side_effect=TimeoutError("test timeout")):
                self.assertEqual(ai_benchmark.main(), 0)
            report = json.loads(Path(output).read_text(encoding="utf-8"))
            self.assertEqual(report["gatePasses"], 0)
            self.assertEqual(report["gateBlocks"], 4)
            self.assertTrue(all(r["gate"] == "BLOCK" for r in report["results"]))

    def test_repeats_runs_each_scenario_multiple_times(self):
        proposals = [
            {"decision": "BLOCK", "amount": 0, "reason": "invoice_not_accepted"}
            for _ in range(8)
        ]
        with tempfile.TemporaryDirectory() as tmp:
            output = str(Path(tmp) / "benchmark.json")
            argv = ["ai_benchmark.py", "--repeats", "2", "--output", output]
            with ExitStack() as stack:
                stack.enter_context(patch.object(sys, "argv", argv))
                ask = stack.enter_context(patch.object(ai_benchmark, "ask_ollama", side_effect=proposals))
                stack.enter_context(patch.object(ai_benchmark, "canonical_decision_reason", side_effect=SystemExit("safe block")))
                self.assertEqual(ai_benchmark.main(), 0)
            report = json.loads(Path(output).read_text(encoding="utf-8"))
            self.assertEqual(ask.call_count, 8)
            self.assertEqual(report["scenarios"], 4)
            self.assertEqual(report["repeatsPerScenario"], 2)
            self.assertEqual(report["cases"], 8)
            self.assertEqual([r["attempt"] for r in report["results"]], [1, 2, 1, 2, 1, 2, 1, 2])


if __name__ == "__main__":
    unittest.main()
