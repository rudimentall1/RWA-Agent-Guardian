"""Conservative but balance-aware EIP-1559 fee quotes for Sepolia deployments."""
import sys

MIN_MAX_FEE_WEI = 10_000_000       # 0.01 gwei; comfortably above the observed Sepolia base fee.
MIN_PRIORITY_FEE_WEI = 1_000_000   # 0.001 gwei; fallback floor when the RPC reports zero.


def parse_quantity(raw):
    """Parse an RPC quantity (hex or decimal), rejecting negative and malformed values."""
    if isinstance(raw, int):
        value = raw
    elif isinstance(raw, str):
        raw = raw.strip().strip('"')
        if not raw:
            raise ValueError("empty RPC quantity")
        value = int(raw, 16) if raw.startswith(("0x", "0X")) else int(raw, 10)
    else:
        raise ValueError("RPC quantity must be a string or integer")
    if value < 0:
        raise ValueError("RPC quantity cannot be negative")
    return value


def quote_eip1559_fees(gas_price, priority_fee=None, base_fee=None):
    """Return (maxFeePerGas, maxPriorityFeePerGas) in wei.

    When baseFeePerGas is available, use the standard 2x-base-fee headroom plus
    the observed priority fee. If the RPC cannot provide a base fee, fall back
    to twice eth_gasPrice plus priority. The minimum fee is deliberately small:
    an unnecessarily high max fee makes clients reserve funds against the whole
    gas limit even when actual Sepolia fees are tiny.
    """
    gas_price = parse_quantity(gas_price)
    if gas_price == 0:
        raise ValueError("eth_gasPrice must be positive")

    parsed_priority = None
    if priority_fee is not None:
        try:
            parsed_priority = parse_quantity(priority_fee)
        except (TypeError, ValueError):
            parsed_priority = None

    parsed_base = None
    if base_fee is not None:
        try:
            parsed_base = parse_quantity(base_fee)
        except (TypeError, ValueError):
            parsed_base = None

    if parsed_priority is None:
        reference = parsed_base if parsed_base is not None else gas_price
        priority = max(reference // 4, MIN_PRIORITY_FEE_WEI)
    else:
        priority = max(parsed_priority, MIN_PRIORITY_FEE_WEI)

    if parsed_base is not None and parsed_base > 0:
        max_fee = max(MIN_MAX_FEE_WEI, parsed_base * 2 + priority)
    else:
        max_fee = max(MIN_MAX_FEE_WEI, gas_price * 2 + priority)

    if priority > max_fee:
        raise ValueError("priority fee cannot exceed max fee")
    return max_fee, priority


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: fee_policy.py <eth_gasPrice> <eth_maxPriorityFeePerGas-or-empty> <baseFeePerGas-or-empty>")
    try:
        max_fee, priority = quote_eip1559_fees(sys.argv[1], sys.argv[2], sys.argv[3])
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"Cannot quote EIP-1559 fees: {exc}") from exc
    print(max_fee, priority)
