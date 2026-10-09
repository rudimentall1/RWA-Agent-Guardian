import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from agent_runner import decode_words, load_agent_private_key


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


if __name__ == "__main__":
    unittest.main()
