# Submission brief

## Project

**RWA Agent Guardian: invoice escrow with onchain mandate enforcement**

The project is a testnet prototype for invoice settlement. A payer accepts a synthetic invoice, deposits a synthetic ERC-20 token into escrow, and grants an executor a payment mandate. The settlement contract enforces invoice state, per-payment and aggregate spending limits, expiry, nonce progression, revocation, and a dispute freeze.

## Problem

A payment agent should not be able to spend an arbitrary amount just because it can initiate a transaction. Invoice settlement needs enforceable limits and an explicit state machine that still holds when a client or executor makes a mistake.

## What is implemented

- Invoice registration and payer acceptance.
- Prefunded escrow settlement with partial payments.
- Per-payment and aggregate mandate caps, expiry, nonce checks, and revocation.
- Dispute freeze and resolver-controlled dispute resolution.
- A payer refund path after the latest mandate expiry.
- Exact token balance-delta checks in the current source.
- A canonical invoice commitment in the current source that binds issuer, invoice ID, payer, beneficiary, token, face value, due date, and document hash.
- Foundry tests for settlement, limits, lifecycle transitions, authorization failures, token-transfer failures, and hash binding.

Ethereum is part of the enforcement boundary, not merely a record of the outcome. The contract rejects settlements that violate its state and mandate checks.

## Honest scope

There is no separately running AI agent or LLM in this version. `DemoAgentExecutor` is a narrow owner-authorized adapter; it is not an autonomous decision engine.

The invoice and dUSD token are synthetic test fixtures. They do not represent a real receivable, legal ownership claim, or regulated asset. The deployed dispute resolver and its administrator are trusted roles. This prototype has not had an independent security audit and is not ready for production funds.

The current public Sepolia deployment is an older version of the contracts. It does not include the latest source-level expiry-refund, resolver-rotation, exact-balance-transfer, or canonical commitment protections. Its configured invoice has already paid 5,000 dUSD against a 5,000 dUSD aggregate mandate cap, so new settlement preflights are expected to return BLOCK. The recording shows the full scenario; the repeatable full-flow test runs against fresh local Foundry state.

A separate exploratory prototype informed the problem choice. This repository implements the invoice lifecycle, escrow settlement, and dispute-state enforcement as a separate codebase, with its own contracts and tests. The repository history records the implementation work for this version.

## Demo and source

- Browser demo: https://rudimentall1.github.io/RWA-Agent-Guardian/
- Browser video player: https://rudimentall1.github.io/RWA-Agent-Guardian/video.html
- GitHub repository: https://github.com/rudimentall1/RWA-Agent-Guardian
- Demo scenario and assertions: [docs/DEMO_SCENARIO.md](DEMO_SCENARIO.md)
- Onchain deployment evidence: [docs/demo-evidence-2026-10-09.md](demo-evidence-2026-10-09.md)

## Technology

Solidity 0.8.24, Foundry, a synthetic ERC-20 token, and a static HTML interface using ethers.js. The demo is deployed on Ethereum Sepolia, chain ID 11155111.

## Reproduce the tests

Run `forge test -vv` and `node --test ui/preflight-policy.test.cjs`.

The deterministic settlement scenario can be run with `forge test --match-test testDemoScenarioAllowsTwoThousandBlocksThreeThousandAndStopsAtFiveThousand -vv`.

The latest checked main branch passed 38 Foundry tests and 2 UI policy tests. These automated checks are not a substitute for an independent security audit.
