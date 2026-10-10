import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch
from urllib.error import URLError
from agent_runner import (
    ask_ollama, build_intent_typed_data, decode_words, extract_transaction_hash,
    load_agent_private_key, parse_ai_decision, validate_config_shape,
    validate_runtime_config, validate_successful_receipt,
)


class AgentRunnerDecodeTests(unittest.TestCase):
    def test_decodes_ten_word_invoice_getter(self):
        values = list(range(10))
        raw = "0x" + "".join(f"{value:064x}" for value in values)
        self.assertEqual(decode_words(raw, 10), values)

    def test_decodes_boolean_mandate_field(self):
        values = [2000, 5000, 0, 123456, 0, 1]
        raw = "0x" + "".join(f"{value:064x}" for value in values)
        decoded = decode_words(raw, 6)
        self.assertEqual(decoded[:5], values[:5])
        self.assertTrue(bool(decoded[5]))

    def test_loads_key_from_wallet_json_file_without_copying_it_to_env(self):
        with tempfile.TemporaryDirectory() as folder:
            wallet_file = Path(folder) / "wallet.json"
            wallet_file.write_text(json.dumps([{"address": "0x" + "11" * 20, "private_key": "0x" + "22" * 32}]))
            with patch.dict(os.environ, {"AGENT_WALLET_FILE": str(wallet_file)}, clear=True):
                self.assertEqual(load_agent_private_key(), "0x" + "22" * 32)

    def test_prefers_explicit_agent_key_over_wallet_file(self):
        with patch.dict(os.environ, {"AGENT_PRIVATE_KEY": "test-key"}, clear=True):
            self.assertEqual(load_agent_private_key(), "test-key")

    def test_rejects_wrong_abi_response_length(self):
        with self.assertRaises(RuntimeError):
            decode_words("0x1234", 10)


    @staticmethod
    def valid_config():
        return {
            "chainId": 11155111,
            "token": "0x" + "1" * 40,
            "settlement": "0x" + "2" * 40,
            "agentExecutor": "0x" + "3" * 40,
            "agentOwner": "0x" + "4" * 40,
            "invoiceId": "0x" + "a" * 64,
        }

    def test_config_requires_chain_addresses_and_bytes32_invoice(self):
        config = self.valid_config()
        config["invoiceId"] = "0x1234"
        with self.assertRaises(SystemExit):
            validate_config_shape(config)

        config = self.valid_config()
        config.pop("agentOwner")
        with self.assertRaises(SystemExit):
            validate_config_shape(config)

    def test_runtime_validation_rejects_chain_mismatch_before_code_checks(self):
        config = self.valid_config()
        with patch("agent_runner.cast", return_value="1") as mocked_cast:
            with self.assertRaises(SystemExit):
                validate_runtime_config(config, "https://rpc.invalid", config["agentOwner"])
        mocked_cast.assert_called_once_with("chain-id", "--rpc-url", "https://rpc.invalid")

    def test_runtime_validation_checks_code_executor_bindings_and_invoice_token(self):
        config = self.valid_config()
        invoice = [0, 0, 0, int(config["token"], 16), 10000, 10000, 0, 0, 0, 2]

        def fake_cast(*args, **kwargs):
            if args[0] == "chain-id":
                return str(config["chainId"])
            if args[0] == "code":
                return "0x60006000"
            if args[0] == "call" and args[2] == "settlement()(address)":
                return config["settlement"]
            if args[0] == "call" and args[2] == "owner()(address)":
                return config["agentOwner"]
            if args[0] == "call" and args[2] == "SETTLEMENT_VERSION()(uint256)":
                return "2"
            if args[0] == "call" and args[2] == "intentDomainSeparator()(bytes32)":
                return "0x" + "c" * 64
            raise AssertionError(f"Unexpected cast call: {args}")

        with patch("agent_runner.cast", side_effect=fake_cast), patch(
            "agent_runner.call_words", return_value=invoice
        ):
            validate_runtime_config(
                config, "https://rpc.invalid", config["agentOwner"], require_signed_intent=True
            )

    def test_runtime_validation_rejects_missing_contract_code(self):
        config = self.valid_config()

        def fake_cast(*args, **kwargs):
            if args[0] == "chain-id":
                return str(config["chainId"])
            if args[0] == "code":
                return "0x"
            raise AssertionError(f"Unexpected cast call: {args}")

        with patch("agent_runner.cast", side_effect=fake_cast):
            with self.assertRaises(SystemExit):
                validate_runtime_config(config, "https://rpc.invalid", config["agentOwner"])


class AgentDecisionTests(unittest.TestCase):
    def test_accepts_bounded_ollama_allow(self):
        result = parse_ai_decision(
            json.dumps({"decision": "ALLOW", "amount": 150, "reason": "Funds and mandate are available"}),
            max_allowed=200,
        )
        self.assertEqual(result["decision"], "ALLOW")
        self.assertEqual(result["amount"], 150)

    def test_rejects_model_amount_above_policy_cap(self):
        with self.assertRaisesRegex(SystemExit, "policy maximum"):
            parse_ai_decision(
                json.dumps({"decision": "ALLOW", "amount": 201, "reason": "try too much"}),
                max_allowed=200,
            )

    def test_wait_and_block_must_have_zero_amount(self):
        with self.assertRaisesRegex(SystemExit, "amount 0"):
            parse_ai_decision(
                json.dumps({"decision": "BLOCK", "amount": 1, "reason": "blocked"}),
                max_allowed=200,
            )

    def test_rejects_boolean_as_integer_amount(self):
        with self.assertRaisesRegex(SystemExit, "non-negative integer"):
            parse_ai_decision(
                json.dumps({"decision": "ALLOW", "amount": True, "reason": "bad type"}),
                max_allowed=200,
            )

    def test_rejects_extra_or_missing_fields(self):
        with self.assertRaisesRegex(SystemExit, "exactly"):
            parse_ai_decision(
                json.dumps({"decision": "ALLOW", "amount": 10, "reason": "ok", "extra": "ignored"}),
                max_allowed=200,
            )

    def test_ollama_request_uses_json_schema_and_parses_content(self):
        payload = {"message": {"content": json.dumps(
            {"decision": "ALLOW", "amount": 75, "reason": "Within the funded limit"}
        )}}
        response = MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(payload).encode("utf-8")
        with patch("agent_runner.urllib.request.urlopen", return_value=response) as open_url:
            decision = ask_ollama(
                {"status": 2}, 100, "qwen2.5:3b", "http://127.0.0.1:11434/api/chat"
            )
        self.assertEqual(decision["amount"], 75)
        request = open_url.call_args.args[0]
        sent = json.loads(request.data.decode("utf-8"))
        self.assertEqual(sent["model"], "qwen2.5:3b")
        self.assertEqual(sent["format"]["additionalProperties"], False)
        self.assertEqual(sent["options"]["temperature"], 0)
        self.assertEqual(sent["options"]["num_ctx"], 2048)
        self.assertEqual(sent["options"]["num_predict"], 128)

    def test_ollama_service_failure_fails_closed(self):
        with patch("agent_runner.urllib.request.urlopen", side_effect=URLError("offline")):
            with self.assertRaisesRegex(SystemExit, "no transaction sent"):
                ask_ollama({}, 100, "qwen2.5:3b", "http://127.0.0.1:11434/api/chat")

    def test_ollama_malformed_model_output_fails_closed(self):
        payload = {"message": {"content": "ALLOW 100"}}
        response = MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(payload).encode("utf-8")
        with patch("agent_runner.urllib.request.urlopen", return_value=response):
            with self.assertRaisesRegex(SystemExit, "valid JSON"):
                ask_ollama({}, 100, "qwen2.5:3b", "http://127.0.0.1:11434/api/chat")

    def test_eip712_typed_data_binds_chain_executor_context_and_decision(self):
        data = build_intent_typed_data(
            11155111,
            "0x" + "3" * 40,
            "0x" + "a" * 64,
            50,
            4,
            1_800_000_000,
            "0x" + "b" * 64,
            "0x" + "c" * 64,
        )
        self.assertEqual(data["domain"]["chainId"], 11155111)
        self.assertEqual(data["domain"]["verifyingContract"], "0x" + "3" * 40)
        self.assertEqual(data["primaryType"], "AgentIntent")
        self.assertEqual(
            [field["name"] for field in data["types"]["AgentIntent"]],
            ["invoiceId", "amount", "nonce", "deadline", "contextHash", "decisionHash"],
        )

    def test_transaction_hash_uses_explicit_json_field_not_block_hash(self):
        tx_hash = "0x" + "a" * 64
        block_hash = "0x" + "b" * 64
        raw = json.dumps({"blockHash": block_hash, "transactionHash": tx_hash})
        self.assertEqual(extract_transaction_hash(raw), tx_hash)

    def test_transaction_hash_fails_closed_for_json_without_hash_field(self):
        raw = json.dumps({"blockHash": "0x" + "b" * 64})
        self.assertIsNone(extract_transaction_hash(raw))

    def test_receipt_requires_success_status_and_matching_hash(self):
        tx_hash = "0x" + "a" * 64
        receipt = validate_successful_receipt(
            json.dumps({
                "transactionHash": tx_hash,
                "status": "0x1",
                "blockNumber": "0x123",
                "gasUsed": "0x456",
            }),
            tx_hash,
        )
        self.assertEqual(receipt["transactionHash"], tx_hash)
        self.assertEqual(receipt["status"], "0x1")
        self.assertEqual(receipt["blockNumber"], "0x123")

    def test_receipt_rejects_revert_status(self):
        with self.assertRaisesRegex(SystemExit, "not successful"):
            validate_successful_receipt(
                json.dumps({"transactionHash": "0x" + "a" * 64, "status": "0x0"}),
                "0x" + "a" * 64,
            )

    def test_receipt_rejects_hash_mismatch(self):
        with self.assertRaisesRegex(SystemExit, "does not match"):
            validate_successful_receipt(
                json.dumps({"transactionHash": "0x" + "b" * 64, "status": "0x1"}),
                "0x" + "a" * 64,
            )

    def test_receipt_rejects_missing_status(self):
        with self.assertRaisesRegex(SystemExit, "no valid status"):
            validate_successful_receipt(
                json.dumps({"transactionHash": "0x" + "a" * 64}),
                "0x" + "a" * 64,
            )

    def test_legacy_settlement_is_rejected_in_signed_intent_mode(self):
        config = AgentRunnerDecodeTests.valid_config()

        def fake_cast(*args, **kwargs):
            if args[0] == "chain-id":
                return str(config["chainId"])
            if args[0] == "code":
                return "0x60006000"
            if args[0] == "call" and args[2] == "settlement()(address)":
                return config["settlement"]
            if args[0] == "call" and args[2] == "owner()(address)":
                return config["agentOwner"]
            if args[0] == "call" and args[2] == "SETTLEMENT_VERSION()(uint256)":
                raise __import__("subprocess").CalledProcessError(1, ["cast"])
            raise AssertionError(f"Unexpected cast call: {args}")

        with patch("agent_runner.cast", side_effect=fake_cast):
            with self.assertRaisesRegex(SystemExit, "settlement is legacy"):
                validate_runtime_config(
                    config, "https://rpc.invalid", config["agentOwner"], require_signed_intent=True
                )

    def test_old_executor_is_rejected_in_signed_intent_mode(self):
        config = AgentRunnerDecodeTests.valid_config()

        def fake_cast(*args, **kwargs):
            if args[0] == "chain-id":
                return str(config["chainId"])
            if args[0] == "code":
                return "0x60006000"
            if args[0] == "call" and args[2] == "settlement()(address)":
                return config["settlement"]
            if args[0] == "call" and args[2] == "owner()(address)":
                return config["agentOwner"]
            if args[0] == "call" and args[2] == "SETTLEMENT_VERSION()(uint256)":
                return "2"
            if args[0] == "call" and args[2] == "intentDomainSeparator()(bytes32)":
                raise __import__("subprocess").CalledProcessError(1, ["cast"])
            raise AssertionError(f"Unexpected cast call: {args}")

        with patch("agent_runner.cast", side_effect=fake_cast):
            with self.assertRaisesRegex(SystemExit, "does not support EIP-712 signed intents"):
                validate_runtime_config(
                    config, "https://rpc.invalid", config["agentOwner"], require_signed_intent=True
                )


if __name__ == "__main__":
    unittest.main()
