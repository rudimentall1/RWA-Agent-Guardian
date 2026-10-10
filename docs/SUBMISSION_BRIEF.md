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

The Ollama decision mode requires a local Ollama service and the updated `DemoAgentExecutor` bytecode. The public executor currently configured for the UI has not been upgraded, so signed-intent mode stops during preflight rather than sending a transaction. Deploy an updated executor and have the payer authorize its address before using AI mode. The deterministic compatibility mode remains available for the legacy demo. The payer must still accept and fund the invoice; the agent-owner key must be separate from the payer key.

Invoice registration is permissionless, but the EIP-712 signature proves only that the named issuer signed the specified terms. It is not legal due diligence or proof that the invoice represents an enforceable receivable. The invoice and dUSD token are synthetic test fixtures; they do not represent a real receivable, legal ownership claim, or regulated asset. The resolver and its administrator remain trusted roles. This prototype has not had an independent security audit and is not ready for production funds.

The UI's configured Sepolia settlement and the earlier deployment used for the recorded three-payment sequence are different contract instances. Both public deployments predate the current dispute-escalation and signed-intent changes: the currently configured settlement still has the timeout-reopens behavior, and its executor lacks the EIP-712 intent interface. The source-level fixes pass CI but are not live at these addresses. `scripts/deploy-sepolia.sh` can create fresh current-source contracts and a fresh synthetic invoice; it does not migrate the previous state. Do not combine the earlier payment receipts with the current UI addresses. Exact addresses and evidence are documented in [the deployment record](demo-evidence-2026-10-09.md).

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
