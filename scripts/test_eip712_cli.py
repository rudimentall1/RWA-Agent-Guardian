"""End-to-end EIP-712 CLI test using a public test-only private key and no network."""
import re
import shutil
import subprocess
import unittest

from agent_runner import build_intent_typed_data, sign_intent
from verify_agent_intent import verify_signature_offline


@unittest.skipUnless(shutil.which("cast"), "Foundry cast is not installed")
class CastEIP712RoundTripTests(unittest.TestCase):
    def test_cast_sign_and_verify_use_the_same_eip712_digest(self):
        # This key is a deterministic test fixture, never a deployment or payer key.
        private_key = "0x" + "0" * 63 + "1"
        signer = subprocess.run(
            ["cast", "wallet", "address", "--private-key", private_key],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()

        typed_data = build_intent_typed_data(
            chain_id=11155111,
            executor="0x2222222222222222222222222222222222222222",
            invoice_id="0x" + "a" * 64,
            amount=1234,
            nonce=7,
            deadline=1_800_000_000,
            context_hash="0x" + "b" * 64,
            decision_hash="0x" + "c" * 64,
        )
        signature = sign_intent(private_key, typed_data)
        self.assertRegex(signature, re.compile(r"^0x[0-9a-fA-F]{130}$"))

        # This invokes cast wallet verify against the same JSON typed-data file.
        verify_signature_offline(typed_data, signature, signer)


if __name__ == "__main__":
    unittest.main()
