# Reproducing the settlement guard scenario

Run the deterministic scenario against fresh Foundry state. The [test implementation is here](https://github.com/rudimentall1/RWA-Agent-Guardian/blob/main/test/InvoiceSettlement.t.sol#L450).

```sh
forge test --match-test testDemoScenarioAllowsTwoThousandBlocksThreeThousandAndStopsAtFiveThousand -vv
```

The test creates a new token and settlement contract for the test run. It exercises this sequence:

1. Settle 2,000 dUSD successfully.
2. Reject a 3,000 dUSD request because it exceeds the 2,000 dUSD per-payment limit.
3. Settle another 2,000 dUSD.
4. Settle the final 1,000 dUSD allowed by the 5,000 dUSD aggregate limit.
5. Reject a further 1 dUSD request because the aggregate limit has been reached.

It then checks that the beneficiary received exactly 5,000 dUSD, the invoice records 5,000 dUSD paid, the mandate spent and nonce are unchanged by rejected requests, and the remaining 5,000 dUSD stays in escrow.

This is a repeatable local contract test, not a claim that the existing public Sepolia invoice can be reset. The published Sepolia invoice is already at its aggregate cap and remains read-only for new successful settlement attempts.

## Deterministic off-chain agent runner

For a fresh deployment with the current source, configure `AGENT_OWNER_ADDRESS` to an address that differs from the payer and is controlled by the `AGENT_PRIVATE_KEY` used by the runner. The payer must accept and fund the invoice and authorize the executor contract first. Then run:

```sh
AGENT_PRIVATE_KEY=0x... \
AGENT_PAYMENT_AMOUNT=2000000000 \
AGENT_INTERVAL_SECONDS=30 \
AGENT_MAX_PAYMENTS=3 \
python3 scripts/agent_runner.py
```

The amount is in token base units, so `2000000000` is 2,000 dUSD for this six-decimal test token. The runner reads the current nonce, remaining funded escrow, and remaining mandate allowance before every payment. With the demo's 2,000 per-payment and 5,000 aggregate caps, the intended run is 2,000, 2,000, then 1,000 dUSD. It cannot bypass a revoked, expired, or exhausted on-chain mandate. Do not put the private key in Git or in the browser UI.

This runner has not yet been exercised against a fresh live Sepolia deployment, and the published video does not yet contain this run.
