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

It checks that the beneficiary received exactly 5,000 dUSD, the invoice records 5,000 dUSD paid, rejected requests do not change mandate spend or nonce, and the remaining 5,000 dUSD stays in escrow.

This is a repeatable local contract test. It does not reset the public Sepolia invoice. That invoice has already reached the aggregate spending cap.

## Deterministic off-chain agent runner

For a fresh deployment, `AGENT_OWNER_ADDRESS` must differ from the payer and match the private key used by the runner. The payer must accept and fund the invoice and authorize the executor contract before the runner starts. The runner polls the invoice and mandate, then signs executions itself. The payer does not need to press Execute for each payment.

Where the agent key is stored in a local JSON wallet file, use the file directly without copying the key into an environment file:

```sh
export AGENT_WALLET_FILE=/root/.config/rwa-agent-guardian/agent-wallet.json
export AGENT_PAYMENT_AMOUNT=2000000000
export AGENT_INTERVAL_SECONDS=30
export AGENT_MAX_PAYMENTS=3
python3 scripts/agent_runner.py
```

The amount is in token base units, so `2000000000` is 2,000 dUSD for this six-decimal test token. With a 2,000 per-payment cap, a 5,000 aggregate cap, and 5,000 dUSD funded in escrow, the intended sequence is 2,000, 2,000, then 1,000 dUSD. Each cycle rereads the on-chain nonce, funded balance, mandate expiry, and remaining authority. The runner cannot bypass a revoked, expired, or exhausted on-chain mandate. Never put a wallet file or private key in Git or in the browser UI.

The fresh live runner scenario and an updated recording must be verified against a new Sepolia deployment before the submission can claim that the payer-free scheduled execution was demonstrated onchain.
