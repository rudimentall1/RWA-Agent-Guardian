import json
import unittest
from unittest.mock import patch

from agent_runner import build_intent_typed_data
from verify_agent_intent import (
    require_version_two_settlement, validate_evidence,
    verify_execution_transaction, verify_signature_offline,
)


class VerifyAgentIntentTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "chainId": 11155111,
            "token": "0x" + "1" * 40,
            "settlement": "0x" + "2" * 40,
            "agentExecutor": "0x" + "3" * 40,
            "agentOwner": "0x" + "4" * 40,
            "invoiceId": "0x" + "a" * 64,
        }
        self.context = {
            "policyVersion": "rwa-agent-policy-v1",
            "chainId": 11155111,
            "executor": self.config["agentExecutor"],
            "settlement": self.config["settlement"],
            "token": self.config["token"],
            "invoiceId": self.config["invoiceId"],
            "invoice": {"status": 2, "funded": 10000, "paid": 0, "dueAt": 1900000000},
            "mandate": {
                "active": True, "perPaymentLimit": 2000, "totalLimit": 5000,
                "spent": 0, "expiresAt": 1800000300, "nonce": 4
            },
            "maxAllowedAmount": 2000,
            "observedAt": 1799999999,
        }
        self.intent_deadline = 1800000300
        self.decision = {
            "decision": "ALLOW",
            "amount": 1000,
            "reason": "Funded escrow and active mandate permit a partial payment",
        }
        self.context_hash = "0x" + "b" * 64
        self.decision_hash = "0x" + "c" * 64
        self.decision_record = {
            "schema": "rwa-agent-decision/v1",
            "policyVersion": "rwa-agent-policy-v1",
            "mode": "ollama",
            "model": "qwen2.5:3b",
            "contextHash": self.context_hash,
            "decision": self.decision["decision"],
            "amount": self.decision["amount"],
            "reason": self.decision["reason"],
        }
        self.signature = "0x" + "1" * 130
        self.typed_data = build_intent_typed_data(
            self.config["chainId"],
            self.config["agentExecutor"],
            self.config["invoiceId"],
            self.decision["amount"],
            self.context["mandate"]["nonce"],
            self.intent_deadline,
            self.context_hash,
            self.decision_hash,
        )
        self.evidence = {
            "schema": "rwa-agent-intent-proof/v1",
            "status": "SIGNED_NOT_EXECUTED",
            "agentSigner": self.config["agentOwner"],
            "model": "qwen2.5:3b",
            "mode": "ollama",
            "context": self.context,
            "contextHash": self.context_hash,
            "decision": self.decision,
            "decisionRecord": self.decision_record,
            "decisionHash": self.decision_hash,
            "intentDeadline": self.intent_deadline,
            "typedData": self.typed_data,
            "signature": self.signature,
            "transactionHash": None,
        }

    def test_online_verifier_requires_settlement_version_two(self):
        with patch("verify_agent_intent.cast", return_value="2") as mocked:
            require_version_two_settlement("https://rpc.invalid", self.config["settlement"])
        mocked.assert_called_once_with(
            "call", self.config["settlement"], "SETTLEMENT_VERSION()(uint256)",
            "--rpc-url", "https://rpc.invalid"
        )

    def test_online_verifier_rejects_legacy_settlement(self):
        with patch("verify_agent_intent.cast", return_value="1"):
            with self.assertRaisesRegex(SystemExit, "expected 2"):
                require_version_two_settlement("https://rpc.invalid", self.config["settlement"])

    def test_online_verifier_rejects_settlement_without_version_method(self):
        import subprocess
        with patch(
            "verify_agent_intent.cast",
            side_effect=subprocess.CalledProcessError(1, ["cast"]),
        ):
            with self.assertRaisesRegex(SystemExit, "is legacy"):
                require_version_two_settlement("https://rpc.invalid", self.config["settlement"])

    def test_valid_evidence_metadata_is_consistent(self):
        with patch(
            "verify_agent_intent.keccak_text",
            side_effect=[self.context_hash, self.decision_hash],
        ):
            checked = validate_evidence(self.evidence, self.config)
        self.assertEqual(checked["decision"]["amount"], 1000)
        self.assertEqual(checked["signer"], self.config["agentOwner"])
        self.assertEqual(checked["decisionHash"], self.decision_hash)

    def test_tampered_context_is_rejected_before_signature_check(self):
        evidence = json.loads(json.dumps(self.evidence))
        evidence["context"]["invoice"]["paid"] = 500
        with patch("verify_agent_intent.keccak_text", return_value="0x" + "d" * 64):
            with self.assertRaisesRegex(SystemExit, "Context hash mismatch"):
                validate_evidence(evidence, self.config)

    def test_untrusted_signer_is_rejected(self):
        evidence = json.loads(json.dumps(self.evidence))
        evidence["agentSigner"] = "0x" + "5" * 40
        with self.assertRaisesRegex(SystemExit, "does not match"):
            validate_evidence(evidence, self.config)

    def test_offline_signature_command_uses_typed_data_and_trusted_signer(self):
        success = f"Validation succeeded. Address {self.config['agentOwner']} signed this message."
        with patch("verify_agent_intent.cast", return_value=success) as mocked_cast:
            verify_signature_offline(self.typed_data, self.signature, self.config["agentOwner"])
        args = mocked_cast.call_args.args
        self.assertEqual(args[:4], ("wallet", "verify", "--data", "--from-file"))
        self.assertEqual(args[-2:], ("--address", self.config["agentOwner"]))

    def test_offline_signature_verification_rejects_failed_cli_result(self):
        with patch("verify_agent_intent.cast", return_value="Validation failed"):
            with self.assertRaisesRegex(SystemExit, "does not recover"):
                verify_signature_offline(
                    self.typed_data, self.signature, self.config["agentOwner"]
                )

    def test_execution_verifier_checks_signed_calldata_and_receipt(self):
        proof = {
            "transactionHash": "0x" + "9" * 64,
            "context": self.context,
            "decision": self.decision,
            "contextHash": self.context_hash,
            "decisionHash": self.decision_hash,
            "intentDeadline": self.intent_deadline,
            "signature": self.signature,
        }
        args = [
            self.config["invoiceId"][2:],
            f"{self.decision['amount']:064x}",
            f"{self.context['mandate']['nonce']:064x}",
            f"{self.intent_deadline:064x}",
            self.context_hash[2:],
            self.decision_hash[2:],
            f"{7 * 32:064x}",
            f"{65:064x}",
        ]
        sig_hex = self.signature[2:]
        padded_signature = sig_hex + "0" * (192 - len(sig_hex))
        calldata = "0xdeadbeef" + "".join(args) + padded_signature

        def fake_cast(*command, **kwargs):
            if command[0] == "tx":
                return json.dumps({"to": self.config["agentExecutor"], "input": calldata})
            if command[0] == "receipt":
                return json.dumps({
                    "transactionHash": "0x" + "9" * 64,
                    "status": "0x1",
                    "logs": [{
                        "address": self.config["settlement"],
                        "topics": [
                            "0xdeadbeef" + "0" * 56,
                            self.config["invoiceId"],
                            "0x" + "0" * 24 + self.config["agentExecutor"][2:],
                        ],
                        "data": "0x" + "".join([
                            f"{self.decision['amount']:064x}",
                            f"{self.context['invoice']['paid'] + self.decision['amount']:064x}",
                            f"{self.context['mandate']['nonce']:064x}",
                        ]),
                    }],
                })
            raise AssertionError(f"Unexpected cast call: {command}")

        with patch("verify_agent_intent.keccak_text", return_value="0xdeadbeef" + "0" * 56), patch(
            "verify_agent_intent.cast", side_effect=fake_cast
        ):
            verify_execution_transaction(proof, "https://rpc.invalid", self.config["agentExecutor"], self.config["settlement"])

    def test_execution_verifier_rejects_receipt_without_settlement_event(self):
        proof = {
            "transactionHash": "0x" + "9" * 64,
            "context": self.context,
            "decision": self.decision,
            "contextHash": self.context_hash,
            "decisionHash": self.decision_hash,
            "intentDeadline": self.intent_deadline,
            "signature": self.signature,
        }
        args = [
            self.config["invoiceId"][2:],
            f"{self.decision['amount']:064x}",
            f"{self.context['mandate']['nonce']:064x}",
            f"{self.intent_deadline:064x}",
            self.context_hash[2:],
            self.decision_hash[2:],
            f"{7 * 32:064x}",
            f"{65:064x}",
        ]
        calldata = "0xdeadbeef" + "".join(args) + self.signature[2:] + "0" * 62

        def fake_cast(*command, **kwargs):
            if command[0] == "tx":
                return json.dumps({"to": self.config["agentExecutor"], "input": calldata})
            if command[0] == "receipt":
                return json.dumps({"status": "0x1", "logs": []})
            raise AssertionError(f"Unexpected cast call: {command}")

        with patch("verify_agent_intent.keccak_text", return_value="0xdeadbeef" + "0" * 56), patch(
            "verify_agent_intent.cast", side_effect=fake_cast
        ):
            with self.assertRaisesRegex(SystemExit, "no matching SettlementExecuted event"):
                verify_execution_transaction(
                    proof, "https://rpc.invalid", self.config["agentExecutor"], self.config["settlement"]
                )

    def test_execution_verifier_rejects_wrong_transaction_parameters(self):
        proof = {
            "transactionHash": "0x" + "9" * 64,
            "context": self.context,
            "decision": self.decision,
            "contextHash": self.context_hash,
            "decisionHash": self.decision_hash,
            "intentDeadline": self.intent_deadline,
            "signature": self.signature,
        }
        args = [
            self.config["invoiceId"][2:],
            f"{999:064x}",  # Different amount from signed intent.
            f"{self.context['mandate']['nonce']:064x}",
            f"{self.intent_deadline:064x}",
            self.context_hash[2:],
            self.decision_hash[2:],
            f"{7 * 32:064x}",
            f"{65:064x}",
        ]
        padded_signature = self.signature[2:] + "0" * 62
        calldata = "0xdeadbeef" + "".join(args) + padded_signature

        def fake_cast(*command, **kwargs):
            if command[0] == "tx":
                return json.dumps({"to": self.config["agentExecutor"], "input": calldata})
            if command[0] == "receipt":
                return json.dumps({
                    "transactionHash": "0x" + "9" * 64,
                    "status": "0x1",
                    "logs": [{
                        "address": self.config["settlement"],
                        "topics": [
                            "0xdeadbeef" + "0" * 56,
                            self.config["invoiceId"],
                            "0x" + "0" * 24 + self.config["agentExecutor"][2:],
                        ],
                        "data": "0x" + "".join([
                            f"{self.decision['amount']:064x}",
                            f"{self.context['invoice']['paid'] + self.decision['amount']:064x}",
                            f"{self.context['mandate']['nonce']:064x}",
                        ]),
                    }],
                })
            raise AssertionError(f"Unexpected cast call: {command}")

        with patch("verify_agent_intent.keccak_text", return_value="0xdeadbeef" + "0" * 56), patch(
            "verify_agent_intent.cast", side_effect=fake_cast
        ):
            with self.assertRaisesRegex(SystemExit, "parameters do not match"):
                verify_execution_transaction(proof, "https://rpc.invalid", self.config["agentExecutor"], self.config["settlement"])


if __name__ == "__main__":
    unittest.main()
