import unittest

from fee_policy import (
    MIN_MAX_FEE_WEI,
    MIN_PRIORITY_FEE_WEI,
    parse_quantity,
    quote_eip1559_fees,
)


class FeePolicyTests(unittest.TestCase):
    def test_uses_current_very_low_sepolia_base_fee_without_artificial_gwei_floor(self):
        max_fee, priority = quote_eip1559_fees(
            "0xf4251", "0xf4240", "0x11"
        )
        self.assertEqual(priority, MIN_PRIORITY_FEE_WEI)
        self.assertEqual(max_fee, MIN_MAX_FEE_WEI)
        # Reserving against the max fee for the current InvoiceSettlement limit
        # should fit this demo deployer's 0.025 ETH testnet balance.
        self.assertLess(16_640_000 * max_fee, 0.001 * 10**18)

    def test_scales_with_real_base_fee_and_priority(self):
        max_fee, priority = quote_eip1559_fees(
            "0x77359400", "0x3b9aca00", "0x3b9aca00"
        )
        self.assertEqual(priority, 1_000_000_000)
        self.assertEqual(max_fee, 3_000_000_000)

    def test_falls_back_when_rpc_does_not_support_priority_or_base_fee(self):
        max_fee, priority = quote_eip1559_fees(
            "0x3b9aca00", "", ""
        )
        self.assertEqual(priority, 250_000_000)
        self.assertEqual(max_fee, 2_250_000_000)

    def test_accepts_decimal_and_hex_quantities(self):
        self.assertEqual(parse_quantity("0xf4240"), 1_000_000)
        self.assertEqual(parse_quantity("1000000"), 1_000_000)

    def test_rejects_bad_or_negative_gas_price(self):
        for bad in ("", "not-hex", "-1", None):
            with self.subTest(value=bad):
                with self.assertRaises(ValueError):
                    quote_eip1559_fees(bad, "0x1", "0x1")


if __name__ == "__main__":
    unittest.main()
