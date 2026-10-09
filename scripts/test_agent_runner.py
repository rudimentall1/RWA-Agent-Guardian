import unittest
from agent_runner import decode_words


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

    def test_rejects_wrong_abi_response_length(self):
        with self.assertRaises(RuntimeError):
            decode_words("0x1234", 10)


if __name__ == "__main__":
    unittest.main()
