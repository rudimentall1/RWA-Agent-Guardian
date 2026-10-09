import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from agent_runner import decode_words, load_agent_private_key, validate_config_shape, validate_runtime_config


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
            raise AssertionError(f"Unexpected cast call: {args}")

        with patch("agent_runner.cast", side_effect=fake_cast), patch(
            "agent_runner.call_words", return_value=invoice
        ):
            validate_runtime_config(config, "https://rpc.invalid", config["agentOwner"])

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


if __name__ == "__main__":
    unittest.main()
