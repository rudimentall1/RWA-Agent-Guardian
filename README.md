# RWA Agent Guardian

**Invoice escrow with onchain mandate enforcement.**

The prototype models a narrow trade-finance flow: an issuer attests to invoice terms, the payer accepts the invoice and funds escrow, and a payer-authorized executor can make capped partial payments to the named beneficiary. `scripts/agent_runner.py` now supports local Ollama inference as well as a deterministic compatibility mode. In AI mode, the model proposes ALLOW, WAIT, or BLOCK; deterministic policy checks bound the proposal, the agent signs an EIP-712 intent, and the updated executor verifies it before asking the settlement contract to enforce the mandate. This is a bounded decision layer, not proof of legal invoice validity or production readiness.

**[Watch the demo in your browser](https://rudimentall1.github.io/RWA-Agent-Guardian/video.html)**

The key rule is about invoice state, not just wallet balance: the executor cannot settle an unaccepted, disputed, or escalated invoice. A timed-out dispute remains frozen until the trusted resolver explicitly resumes or cancels it. Each mandate has a per-payment cap, an aggregate cap, an expiry, and a monotonic nonce. The source checks exact token balance changes, supports resolver rotation by a privileged admin, and includes expiry-related escrow paths. The UI's `InvoiceSettlement` address refers to the later settlement deployment, but its configured `DemoAgentExecutor` is still the legacy bytecode and does not expose the new signed-intent interface. The older deployment used for the recorded three-payment sequence is a separate instance. The AI mode refuses to send until an upgraded executor is deployed and authorized. See the deployment evidence for the exact addresses and transaction history.

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
- AI mode requires a local Ollama endpoint, a separately configured agent-owner key, an upgraded `DemoAgentExecutor` with the EIP-712 intent interface, and a payer-created mandate for that executor. The public executor currently configured for the UI is the legacy version; AI mode detects this and stops before sending. Deploy the upgraded executor and have the payer authorize it before running AI mode. `AGENT_DECISION_MODE=deterministic` remains available for the legacy demo and does not use AI.

This is a hackathon prototype, not an audited financial product. The invoice and payment token are synthetic; no real receivable, legal ownership claim, or regulated asset is represented. The resolver remains a trusted role, and its admin remains privileged. Production use would need a real invoice document with a verifiable issuer attestation, a real governance/dispute process, and independent review.

## Browser demo and Sepolia deployment

The demo is a static page in **ui/**. It requires an injected wallet connected to Sepolia and public contract addresses in **ui/config.js**. Start the page from a local HTTP server rather than opening the file directly:

    cd ui
    python3 -m http.server 8091

For a fresh deployment, copy **.env.example** to **.env** and set the deployer key, payer wallet, beneficiary address, and `AGENT_OWNER_ADDRESS` locally. The agent-owner address must differ from the payer and be controlled by the private key supplied to the runner. Keep **.env** out of Git. Then run:

    set -a
    source ./.env
    set +a
    bash scripts/deploy-sepolia.sh

The script deploys a synthetic payment token, the settlement contract, and a narrow agent executor in sequence with explicit gas limits. It signs the initial invoice terms using EIP-712, stops when any transaction fails, registers the attested demo invoice, mints test tokens to the payer, and writes public addresses to deployment config files. The New invoice button lets any connected issuer register its own signed statement; the payer must still be a different wallet and must accept and fund the invoice. Copy the resulting public addresses into **ui/config.js** based on **ui/config.example.js**. The payer must accept the invoice, approve and fund escrow, and authorize the executor before running the valid and over-limit scenarios. The **New invoice** button creates another synthetic invoice with the same payer, beneficiary, and face value; use an issuer wallet different from the payer to register it, then reconnect as the payer to accept and fund it. The UI currently points at a legacy executor, so it cannot verify signed AI intents until that executor is upgraded. To deploy only the new executor against the configured settlement, set `DEPLOYER_PRIVATE_KEY` in your shell and run `bash scripts/deploy-intent-executor-sepolia.sh`. This helper verifies the chain, existing invoice, token, settlement and UI config, deploys one executor, checks its bytecode and immutable bindings, then updates the local public config files. It does not deploy or alter the settlement, token, invoice, escrow, or prior payment history. Commit/publish the updated `ui/config.js` when ready, then connect the configured payer and authorize the new executor onchain; an old executor mandate does not automatically transfer.\n\nTo run the AI-backed agent, configure `AGENT_PRIVATE_KEY` (matching `agentOwner`) or `AGENT_WALLET_FILE` (outside the repository), make sure a local Ollama service is reachable at `AGENT_AI_URL` (default `http://127.0.0.1:11434/api/chat`) and the selected `AGENT_AI_MODEL` is installed (default `qwen2.5:3b`), then run `AGENT_DECISION_MODE=ollama python3 scripts/agent_runner.py`. AI output is strict-schema validated, bounded by onchain-derived limits and signed as an EIP-712 intent. It writes a JSON context/decision/signature record to `agent-evidence/` by default, configurable with `AGENT_EVIDENCE_DIR`. Verify a record with `python3 scripts/verify_agent_intent.py agent-evidence/<proof>.json`; this checks the signature and hashes offline, then checks the executor and (for an executed payment) the calldata and receipt against Sepolia. Add `--offline-only` when no RPC is available. `AGENT_AI_TIMEOUT_SECONDS` defaults to 300 seconds for cold local model startup. For the legacy deterministic demo, run `AGENT_DECISION_MODE=deterministic python3 scripts/agent_runner.py`. `AGENT_PAYMENT_AMOUNT`, `AGENT_INTERVAL_SECONDS`, and `AGENT_MAX_PAYMENTS` set the cap, interval, and execution count.

## Submission brief

A concise summary of the problem, implementation, demo links, test commands, provenance, and limitations is available in [docs/SUBMISSION_BRIEF.md](docs/SUBMISSION_BRIEF.md).

## Demo recording

The walkthrough has a browser-based player at [Watch the demo](https://rudimentall1.github.io/RWA-Agent-Guardian/video.html). The MP4 is also kept in **demo/** in this repository. The player uses the same video file and supports playback and seeking without requiring a manual download.

The earlier deployment shown in the recorded payment sequence has reached its 5,000 dUSD aggregate spending limit, so further settlements on that invoice should return BLOCK. The current UI points to a separate later Sepolia deployment with a fresh demo state. It is not a resettable sandbox, and the two deployments must not be presented as one transaction history. See [the deployment evidence](docs/demo-evidence-2026-10-09.md) before quoting addresses or payment receipts.

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
- The earlier Sepolia instance used for the recorded three-payment sequence is separate from the later instance configured in the UI. They have different state and transaction histories. The current UI deployment corresponds to the current contract source; see [deployment evidence](docs/demo-evidence-2026-10-09.md).
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
