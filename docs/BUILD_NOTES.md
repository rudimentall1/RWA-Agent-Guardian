# Build notes

## Scope selected for the official sprint

The implementation focuses on the invoice payment lifecycle rather than guarding a generic token transfer:

1. Issuer registers the terms commitment and named parties.
2. Payer accepts the invoice.
3. Payer funds escrow.
4. Payer grants and can revoke a narrowly capped agent mandate.
5. Agent submits partial settlements using a monotonic nonce and a deadline.
6. The payer can freeze settlement by disputing the invoice. Invoice maturity is recorded separately from the agent mandate expiry, so a late settlement can still proceed if the payer's mandate and execution deadline remain valid.
7. A designated resolver can resume or cancel a dispute; cancellation refunds the unpaid escrow.

## Decisions and trade-offs

- **Single contract for the MVP:** fewer moving parts to audit during a short sprint. Invoice lifecycle, escrow, and the mandate are intentionally kept together.
- **Prefunded escrow:** avoids giving the agent custody of the payer's key, but requires the payer to lock funds before automated settlement.
- **Explicit dispute resolver:** provides a demoable path to resolve a freeze, but introduces trust in that role. It is not suitable as a production governance design.
- **Synthetic assets only:** the invoice and test token are test fixtures, not legal or economic claims on real-world assets.

## Prior exploration

A separate prototype was built before the event and informed the choice of problem. This implementation focuses on invoice acceptance, escrow settlement, and dispute-state enforcement rather than a generic token-transfer guard. The repository history records the implementation work for this version.


## Sepolia gas repricing (9 October 2026)

Sepolia activated Glamsterdam on 6 October. The EIP-8037/EIP-8038 changes reprice state creation and access, so the old fixed deployment limits were no longer reliable. The first token deployment's receipt showed `status=0x0` and exactly the 3,000,000 gas limit; the predicted address had no code. The live RPC currently estimates about 3.12M gas for `DemoSettlementToken`, 11.50M for `InvoiceSettlement`, and 1.28M for `DemoAgentExecutor`.

`scripts/deploy-sepolia.sh` now estimates the full constructor payload against the selected RPC before broadcasting each deployment and adds 35% headroom. It refuses to submit if that margin would exceed the configured ceiling below the 16,777,216 per-transaction gas cap. The script still checks receipt status and deployed bytecode before proceeding. These estimates are specific to the current testnet rules and should be recomputed on the target RPC rather than copied into future scripts.

## Hardening added before submission

- The settlement admin now maintains an issuer allowlist. This is a permissioning control, not a legal attestation or proof that an invoice is a real receivable.
- An unresolved dispute automatically reopens after seven days if the resolver has not acted. This avoids an indefinite protocol-level freeze but does not adjudicate the commercial dispute.
- After the due date plus a 30-day grace period, and after the latest mandate expiry, the named beneficiary can claim the remaining funded escrow. The payer refund path is restricted to the grace window.
- `scripts/agent_runner.py` is a deterministic off-chain scheduler. It reads the on-chain invoice and executor mandate, caps each payment to funded escrow and remaining mandate authority, and calls the executor using a separate agent-owner key. It is not an LLM or a production-grade autonomous agent.
- `test/InvoiceSettlementInvariant.t.sol` checks accounting and mandate invariants. CI now runs coverage and Slither with three documented detector exclusions for intentional balance-delta checks, event ordering, and timestamp-based expiry logic.
