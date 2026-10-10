# RWA Agent Guardian

**Invoice escrow with onchain mandate enforcement.**

The prototype models a narrow trade-finance flow: an issuer attests to invoice terms, the payer accepts the invoice and funds escrow, and a payer-authorized executor can make capped partial payments to the named beneficiary. `scripts/agent_runner.py` supports local Ollama inference as well as a deterministic compatibility mode. In AI mode, the model proposes ALLOW, WAIT, or BLOCK using a strict reason-code schema; the deterministic gate rejects contradictory proposals, canonicalizes the explanation from checked facts, and the agent signs an EIP-712 intent before the executor asks the settlement contract to enforce the mandate. [The local inference tests and their limitations](docs/ai-inference-evidence-2026-10-10.md) are documented separately. This is a bounded decision layer, not proof of legal invoice validity or production readiness.

**[Watch the demo in your browser](https://rudimentall1.github.io/RWA-Agent-Guardian/video.html)**

The key rule is about invoice state, not just wallet balance: the executor cannot settle an unaccepted, disputed, or escalated invoice. A timed-out dispute remains frozen until the trusted resolver explicitly resumes or cancels it. Each mandate has a per-payment cap, an aggregate cap, an expiry, and a monotonic nonce. The source checks exact token balance changes, supports resolver rotation by a privileged admin, and includes expiry-related escrow paths. The current public UI points to the fresh Sepolia v2 deployment recorded in [the 2026-10-10 deployment evidence](docs/deployment-evidence-2026-10-10.md): the settlement reports `SETTLEMENT_VERSION=2`, and the executor exposes the signed-intent domain interface. Earlier Sepolia instances remain separate legacy deployments; their state and receipts must not be combined with the current UI deployment. The current invoice is newly registered and still needs payer acceptance, escrow funding, and executor authorization before it can settle. To deploy another fresh pair, use `scripts/deploy-sepolia.sh`; it does not migrate state.

## Current scope

- One Solidity settlement contract, a synthetic ERC-20 payment token, and a narrow agent executor.
- A separate test-only token fixture.
- A synthetic invoice record with a canonical commitment over issuer, invoice ID, payer, beneficiary, token, face value, due date, and document hash. The source requires an EIP-712 issuer signature over those fields plus chain, contract, nonce, and deadline.
- Explicit lifecycle: REGISTERED to ACCEPTED, then DISPUTED, ESCALATED after a seven-day unresolved dispute timeout, SETTLED, CANCELLED, or CLAIMED. ESCALATED stays frozen until the resolver explicitly resumes or cancels the invoice.
- EIP-712 issuer attestations plus payer-controlled executor authorization, revocation, per-payment and aggregate limits.
- Partial settlement, nonce/deadline checks, escrow accounting, late settlement under a still-valid mandate, and dispute freeze.
- Foundry tests for allowed settlement and important failure paths.

## Important limitations

- Any wallet may register an invoice only by signing the exact terms with EIP-712. The signature shows which issuer made the assertion; it does not prove that the invoice is true, enforceable, owned, or collectible. A beneficiary can claim remaining funded escrow only after the due date plus a 30-day grace period and after the latest mandate expiry; the payer refund path is limited to that grace window.
- AI mode requires a local Ollama endpoint, a separately configured agent-owner key, an executor with the EIP-712 intent interface, and a payer-created mandate for that executor. The current public UI now uses the upgraded executor, but the payer still has to accept the invoice, fund escrow, and authorize the executor before AI mode can execute a payment. AI mode stops rather than sending if those prerequisites or the signed-intent checks fail. `AGENT_DECISION_MODE=deterministic` remains available for the older compatibility demo and does not use AI.

This is a hackathon prototype, not an audited financial product. The invoice and payment token are synthetic; no real receivable, legal ownership claim, or regulated asset is represented. The resolver remains a trusted role, and its admin remains privileged. Production use would need a real invoice document with a verifiable issuer attestation, a real governance/dispute process, and independent review.

## Browser demo and Sepolia deployment

The demo is a static page in **ui/**. It requires an injected wallet connected to Sepolia and public contract addresses in **ui/config.js**. Start the page from a local HTTP server rather than opening the file directly:

    cd ui
    python3 -m http.server 8091

For a fresh deployment, copy **.env.example** to **.env** and set the deployer key, payer wallet, beneficiary address, and `AGENT_OWNER_ADDRESS` locally. The agent-owner address must differ from the payer and be controlled by the private key supplied to the runner. Keep **.env** out of Git.

Run the read-only preflight first. It checks the RPC chain, estimates the three constructors, quotes live transaction fees, and compares the reserve plus a safety buffer with the deployer's balance. It does not broadcast transactions:

    set -a
    source ./.env
    set +a
    export DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
    bash scripts/preflight-deploy-sepolia.sh

If preflight passes, deploy the fresh contracts:

    bash scripts/deploy-sepolia.sh

The deployment script verifies that the RPC chain ID is Sepolia (`11155111`) before broadcasting, derives transaction fees from the live RPC unless explicit fee values are supplied, and stops if a reused settlement is not `SETTLEMENT_VERSION=2` or a reused executor lacks the signed-intent interface. It signs the initial invoice terms with EIP-712, registers the synthetic invoice, mints the payer's demo tokens, and writes the public addresses to `deployments-sepolia.json` and `ui/config.js`. A fresh run creates new instances; it does not migrate or alter prior invoices, escrow balances, or payment receipts. After deployment, publish the updated UI config, connect the payer wallet, accept the invoice, approve and fund escrow, and authorize the executor. The **New invoice** button creates another synthetic invoice; register it with an issuer wallet different from the payer, then reconnect as payer to accept and fund it.

The executor-only helper `scripts/deploy-intent-executor-sepolia.sh` is for adding the intent-enabled executor to a settlement that is already version 2; it explicitly rejects legacy settlements. The current public UI already points to a fresh v2 settlement/executor pair. Use the full deployment script above when creating a new pair and invoice.

To run the AI-backed agent, configure `AGENT_PRIVATE_KEY` (matching `agentOwner`) or `AGENT_WALLET_FILE` (outside the repository), make sure a local Ollama service is reachable at `AGENT_AI_URL` (default `http://127.0.0.1:11434/api/chat`) and the selected `AGENT_AI_MODEL` is installed (default `qwen2.5:3b`), then run `AGENT_DECISION_MODE=ollama python3 scripts/agent_runner.py`. AI output is schema-validated, bounded by onchain-derived limits, rechecked against fresh invoice/mandate state after inference, and signed as an EIP-712 intent. The model's reason code must agree with the policy facts; a contradiction stops the run without sending. A JSON context/decision/signature record is written to `agent-evidence/` by default, configurable with `AGENT_EVIDENCE_DIR`. Verify a record with `python3 scripts/verify_agent_intent.py agent-evidence/<proof>.json`; this checks the signature and hashes offline, then checks settlement version, executor verification and (for an executed payment) calldata, event, and receipt against Sepolia. Add `--offline-only` when no RPC is available. `AGENT_AI_TIMEOUT_SECONDS` defaults to 300 seconds for cold local model startup. [Live local inference results](docs/ai-inference-evidence-2026-10-10.md) cover synthetic cases only; they are not payment receipts. For the legacy deterministic demo, run `AGENT_DECISION_MODE=deterministic python3 scripts/agent_runner.py`. `AGENT_PAYMENT_AMOUNT`, `AGENT_INTERVAL_SECONDS`, and `AGENT_MAX_PAYMENTS` set the cap, interval, and execution count.

## Submission brief

A concise summary of the problem, implementation, demo links, test commands, provenance, and limitations is available in [docs/SUBMISSION_BRIEF.md](docs/SUBMISSION_BRIEF.md).

## Demo recording

The walkthrough has a browser-based player at [Watch the demo](https://rudimentall1.github.io/RWA-Agent-Guardian/video.html). The MP4 is also kept in **demo/** in this repository. The player uses the same video file and supports playback and seeking without requiring a manual download.

The earlier deployment shown in the recorded payment sequence has reached its 5,000 dUSD aggregate spending limit, so further settlements on that invoice should return BLOCK. The current UI points to a separate, fresh v2 Sepolia deployment. It is not a resettable sandbox, and the deployments must not be presented as one transaction history. See [current deployment evidence](docs/deployment-evidence-2026-10-10.md) and [the recorded demo evidence](docs/demo-evidence-2026-10-09.md) before quoting addresses or payment receipts.

## Threat model

### Assets to protect

- Synthetic ERC-20 funds held in escrow.
- Invoice state, funded and paid accounting, and the mandate's nonce, limits, and expiry.
- The payer's ability to authorize or revoke the executor.
- The beneficiary address and the integrity of the invoice terms signed by the issuer.

### Trust assumptions

- The deployer controls dispute-resolver administration. Issuers self-attest to the exact invoice terms; the contract verifies the signature, not legal truth.
- The issuer signs its own EIP-712 statement. A signature confirms who signed the stated terms, not whether the invoice is legally valid or the underlying debt exists.
- The payer accepts the invoice, funds escrow, and authorizes the executor.
- The agent operator protects its key. A compromised key can spend only within the mandate, but can spend that allowance maliciously.
- The token is expected to be a conventional ERC-20. Exact balance checks reject fee-on-transfer behavior but cannot make arbitrary token code trustworthy.

### Controls

- EIP-712 attestation over invoice fields, chain, contract, nonce, and deadline.
- Canonical low-s ECDSA recovery, an issuer nonce, a signature deadline, and an onchain attestation digest with the signature in an event.
- Invoice lifecycle checks, exact token balance deltas, a reentrancy guard, mandate limits, expiry, and execution nonces.
- Regression and invariant tests for escrow coverage, payments, authority limits, signature validation, and nonce replay.

### Known gaps

- Invoice and token are synthetic. The document hash is not proof of ownership, delivery, enforceability, or collectible value. This repository does not include an ERC-721 claim token or a transfer of legal title.
- At timeout, an unresolved DISPUTED invoice moves to ESCALATED and remains frozen until the dispute resolver explicitly resumes execution or cancels and refunds the invoice.
- The earlier Sepolia instance used for the recorded three-payment sequence is separate from the fresh v2 instance configured in the UI. They have different state and transaction histories. On 2026-10-10, read-only Sepolia checks confirmed that the current UI settlement exposes the `ESCALATED`-capable v2 version marker and its executor exposes the signed-intent interface; the earlier instance remains legacy. See [current deployment evidence](docs/deployment-evidence-2026-10-10.md) and [recorded demo evidence](docs/demo-evidence-2026-10-09.md).
- No independent audit has been performed. Do not use this prototype to hold real assets.

The fuller version is available in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## Build and test

Requires Foundry and Solidity 0.8.24.

    forge test -vv

To reproduce the full 2,000 dUSD ALLOW, 3,000 dUSD BLOCK, 5,000 dUSD aggregate-cap, and post-cap BLOCK sequence against fresh local test state, run:

    forge test --match-test testDemoScenarioAllowsTwoThousandBlocksThreeThousandAndStopsAtFiveThousand -vv

See [docs/DEMO_SCENARIO.md](docs/DEMO_SCENARIO.md) for the exact sequence and assertions. The [test source and scenario function](https://github.com/rudimentall1/RWA-Agent-Guardian/blob/main/test/InvoiceSettlement.t.sol#L450) are linked directly for review. This local scenario does not reset or alter the public Sepolia deployment.

## Build provenance

A separate exploratory prototype informed the choice of problem. This repository implements the invoice acceptance, escrow settlement, and dispute lifecycle as a separate codebase, with its own contracts and Foundry tests. The demo uses synthetic assets and does not represent a real receivable or legal claim.
