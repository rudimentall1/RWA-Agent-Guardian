# Submission brief

## Project

**RWA Agent Guardian: invoice escrow with onchain mandate enforcement**

This is a testnet prototype for invoice settlement. An issuer registers a synthetic invoice, a payer accepts and funds it, and a narrow executor can make capped partial payments. The current source includes an optional local Ollama decision component plus a deterministic compatibility mode. In AI mode, model proposals pass a strict policy gate, the agent signs an EIP-712 intent over the on-chain context and decision hashes, the executor verifies the signature, and the settlement contract remains the final spending control.

## Problem

A payment agent should not be able to spend an arbitrary amount just because it can initiate a transaction. Invoice settlement needs enforceable limits and an explicit state machine that still holds when a client or executor makes a mistake.

## What is implemented in the current source

- Permissionless invoice registration with a required EIP-712 issuer signature. The signature binds invoice terms and document hash to chain ID, settlement contract, nonce, and deadline; it is not proof of legal validity.
- Invoice registration and payer acceptance.
- Prefunded escrow settlement with partial payments.
- Per-payment and aggregate mandate caps, expiry, nonce checks, and revocation.
- Dispute freeze, resolver-controlled resolution, and a seven-day timeout that escalates an unresolved invoice while keeping settlement frozen until the resolver acts.
- A payer refund path within the maturity grace window and a beneficiary claim for remaining funded escrow after the due date plus 30 days and expiry of the latest mandate.
- Exact token balance-delta checks and a canonical invoice commitment binding issuer, invoice ID, payer, beneficiary, token, face value, due date, and document hash.
- A local Ollama-backed ALLOW/WAIT/BLOCK proposal with strict JSON, categorical reason codes and amount-cap validation; deterministic rejection of a reason code that contradicts policy facts; signed context and decision hashes; on-chain EIP-712 signature verification in the updated executor; a JSON evidence record under `agent-evidence/`; and `scripts/verify_agent_intent.py` to verify hashes, signer, typed data, transaction calldata, settlement event, and receipt. [Live local inference evidence](ai-inference-evidence-2026-10-10.md) records two synthetic cases and a smaller model's rejected contradictory answer.
- Foundry regression tests, three invariant properties, coverage reporting, and Slither analysis in CI.
- A `New invoice` UI action that lets an issuer create a signed invoice from its connected wallet on deployments with the current attestation interface.

Ethereum is part of the enforcement boundary, not merely a record of the outcome. The contract rejects settlements that violate its state and mandate checks.

## Honest scope and limitations

The Ollama decision mode requires a local Ollama service and an executor with the EIP-712 intent interface. The current public UI points to the newly deployed v2 `DemoAgentExecutor`, and read-only Sepolia checks confirmed that its intent domain is available. The new invoice is registered, but it is not yet accepted or funded and the executor mandate is not active; the payer must accept the invoice, fund escrow, and authorize the executor before AI mode can execute. The agent-owner key must remain separate from the payer key. The deterministic compatibility mode remains available for the older demo.

Invoice registration is permissionless, but the EIP-712 signature proves only that the named issuer signed the specified terms. It is not legal due diligence or proof that the invoice represents an enforceable receivable. The invoice and dUSD token are synthetic test fixtures; they do not represent a real receivable, legal ownership claim, or regulated asset. The resolver and its administrator remain trusted roles. This prototype has not had an independent security audit and is not ready for production funds.

The current UI's Sepolia settlement and executor are a fresh v2 pair deployed on 2026-10-10. Read-only RPC checks confirmed `SETTLEMENT_VERSION() == 2`, a working `intentDomainSeparator()`, and code at both contract addresses. The earlier deployment used for the recorded three-payment sequence is separate and remains legacy; do not combine its payment receipts with the current UI's addresses or invoice state. The new deployment has only registered the synthetic invoice and minted demo tokens to the payer: no acceptance, escrow funding, executor authorization, or payment is claimed. `scripts/deploy-sepolia.sh` creates fresh instances rather than migrating prior state. Exact addresses, receipt hashes, and checks are documented in [the current deployment record](deployment-evidence-2026-10-10.md) and [the older demo record](demo-evidence-2026-10-09.md).

A separate exploratory prototype informed the problem choice. This repository implements the invoice lifecycle, escrow settlement, and dispute-state enforcement as a separate codebase. The repository history should be used to assess what was built during the event; no claim is made that the broader idea originated during the event.

## Demo and source

- Browser demo: https://rudimentall1.github.io/RWA-Agent-Guardian/
- Browser video player: https://rudimentall1.github.io/RWA-Agent-Guardian/video.html
- GitHub repository: https://github.com/rudimentall1/RWA-Agent-Guardian
- Demo scenario and assertions: [docs/DEMO_SCENARIO.md](DEMO_SCENARIO.md)
- Threat model: [docs/THREAT_MODEL.md](THREAT_MODEL.md)
- Current onchain deployment evidence: [docs/deployment-evidence-2026-10-10.md](deployment-evidence-2026-10-10.md)
- Recorded earlier demo receipts: [docs/demo-evidence-2026-10-09.md](demo-evidence-2026-10-09.md)

## Technology

Solidity 0.8.24, Foundry, a synthetic ERC-20 token, a deterministic Python runner using Foundry's `cast`, and a static HTML interface using ethers.js. The existing demo is deployed on Ethereum Sepolia, chain ID 11155111.

## Reproduce the checks

Run `forge test -vv`, `forge coverage`, `node --test ui/preflight-policy.test.cjs`, and `python -m unittest discover -s scripts -p 'test_*.py'`.

The deterministic settlement scenario can be run with `forge test --match-test testDemoScenarioAllowsTwoThousandBlocksThreeThousandAndStopsAtFiveThousand -vv`. Invariant tests run 32 campaigns at depth 32. Coverage is not proof of correctness and is not a substitute for an independent security audit.
