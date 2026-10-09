# Submission brief

## Project

**RWA Agent Guardian: invoice escrow with onchain mandate enforcement**

This is a testnet prototype for invoice settlement. An issuer registers a synthetic invoice, a payer accepts and funds it, and a narrow executor can make capped partial payments. The current source includes a deterministic off-chain scheduler that submits payments through the executor using a separate agent-owner key. It is not an LLM or an autonomous reasoning agent.

## Problem

A payment agent should not be able to spend an arbitrary amount just because it can initiate a transaction. Invoice settlement needs enforceable limits and an explicit state machine that still holds when a client or executor makes a mistake.

## What is implemented in the current source

- Permissionless invoice registration with a required EIP-712 issuer signature. The signature binds invoice terms and document hash to chain ID, settlement contract, nonce, and deadline; it is not proof of legal validity.
- Invoice registration and payer acceptance.
- Prefunded escrow settlement with partial payments.
- Per-payment and aggregate mandate caps, expiry, nonce checks, and revocation.
- Dispute freeze, resolver-controlled resolution, and a seven-day timeout that reopens an unresolved invoice.
- A payer refund path within the maturity grace window and a beneficiary claim for remaining funded escrow after the due date plus 30 days and expiry of the latest mandate.
- Exact token balance-delta checks and a canonical invoice commitment binding issuer, invoice ID, payer, beneficiary, token, face value, due date, and document hash.
- A deterministic off-chain runner in `scripts/agent_runner.py` that executes only within on-chain mandate authority.
- Foundry regression tests, three invariant properties, coverage reporting, and Slither analysis in CI.
- A `New invoice` UI action that lets an issuer create a signed invoice from its connected wallet on deployments with the current attestation interface.

Ethereum is part of the enforcement boundary, not merely a record of the outcome. The contract rejects settlements that violate its state and mandate checks.

## Honest scope and limitations

The agent runner is a deterministic scheduler, not an LLM. The payer must still accept and fund the invoice and authorize the executor contract before scheduled payments can run. The agent-owner key must be separate from the payer key.

Invoice registration is permissionless, but the EIP-712 signature proves only that the named issuer signed the specified terms. It is not legal due diligence or proof that the invoice represents an enforceable receivable. The invoice and dUSD token are synthetic test fixtures; they do not represent a real receivable, legal ownership claim, or regulated asset. The resolver and its administrator remain trusted roles. This prototype has not had an independent security audit and is not ready for production funds.

The UI's configured Sepolia deployment and the earlier deployment used for the recorded three-payment sequence are different contract instances. The current UI deployment was built from the current contract source and has its own invoice and mandate state; the earlier instance has reached its 5,000 dUSD aggregate cap. Do not combine the earlier payment receipts with the current UI addresses. Exact addresses and evidence are documented in [the deployment record](demo-evidence-2026-10-09.md). The deterministic runner exists in source, but its scheduled execution should be described as live only when supported by its own transaction receipts.

A separate exploratory prototype informed the problem choice. This repository implements the invoice lifecycle, escrow settlement, and dispute-state enforcement as a separate codebase. The repository history should be used to assess what was built during the event; no claim is made that the broader idea originated during the event.

## Demo and source

- Browser demo: https://rudimentall1.github.io/RWA-Agent-Guardian/
- Browser video player: https://rudimentall1.github.io/RWA-Agent-Guardian/video.html
- GitHub repository: https://github.com/rudimentall1/RWA-Agent-Guardian
- Demo scenario and assertions: [docs/DEMO_SCENARIO.md](DEMO_SCENARIO.md)
- Threat model: [docs/THREAT_MODEL.md](THREAT_MODEL.md)
- Onchain deployment evidence: [docs/demo-evidence-2026-10-09.md](demo-evidence-2026-10-09.md)

## Technology

Solidity 0.8.24, Foundry, a synthetic ERC-20 token, a deterministic Python runner using Foundry's `cast`, and a static HTML interface using ethers.js. The existing demo is deployed on Ethereum Sepolia, chain ID 11155111.

## Reproduce the checks

Run `forge test -vv`, `forge coverage`, `node --test ui/preflight-policy.test.cjs`, and `python -m unittest discover -s scripts -p 'test_*.py'`.

The deterministic settlement scenario can be run with `forge test --match-test testDemoScenarioAllowsTwoThousandBlocksThreeThousandAndStopsAtFiveThousand -vv`. Invariant tests run 32 campaigns at depth 32. Coverage is not proof of correctness and is not a substitute for an independent security audit.
