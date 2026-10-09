# Reproducing the settlement guard scenario

Run the deterministic scenario against fresh Foundry state:

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
