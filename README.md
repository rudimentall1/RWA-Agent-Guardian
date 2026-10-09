# RWA Agent Guardian

**Escrow settlement for agent-operated invoice payments.**

The prototype models a narrow, testable trade-finance flow: an issuer registers an invoice record, the payer accepts it, funds are deposited into escrow, and a payer-authorized executor contract can make capped partial payments to the named beneficiary. There is no separately running AI agent or LLM in this version.

**[Watch the demo in your browser](https://rudimentall1.github.io/RWA-Agent-Guardian/video.html)**

The key rule is about invoice state, not just wallet balance: the executor cannot settle an unaccepted or disputed invoice. Each mandate has a per-payment cap, an aggregate cap, an expiry, and a monotonic nonce. The source now checks exact token balance changes, supports resolver rotation by a privileged admin, and lets the payer recover unused escrow after the latest mandate expiry. These source-level hardening changes are not active on the already deployed Sepolia contracts.

## Current scope

- One Solidity settlement contract, a synthetic ERC-20 payment token, and a narrow agent executor.
- A separate test-only token fixture.
- A synthetic invoice record storing a terms hash alongside the payer, beneficiary, payment token, face value, and due date. The current hash covers only a fixed synthetic descriptor, not all of those fields.
- Explicit lifecycle: REGISTERED to ACCEPTED, then DISPUTED, SETTLED, or CANCELLED.
- Payer-controlled agent authorization, revocation, per-payment and aggregate limits.
- Partial settlement, nonce/deadline checks, escrow accounting, late settlement under a still-valid mandate, and dispute freeze.
- Foundry tests for allowed settlement and important failure paths.

## Important limitations

This is a hackathon prototype, not an audited financial product. The invoice and payment token are synthetic; no real receivable, legal ownership claim, or regulated asset is represented. The resolver remains a trusted role, and its admin remains privileged. Production use would need a real governance/dispute process, a canonical invoice digest that binds all material fields, and independent review.

## Browser demo and Sepolia deployment

The demo is a static page in **ui/**. It requires an injected wallet connected to Sepolia and public contract addresses in **ui/config.js**. Start the page from a local HTTP server rather than opening the file directly:

    cd ui
    python3 -m http.server 8091

For a deployment, copy **.env.example** to **.env** and set the deployer key, payer wallet, and beneficiary address locally. Keep **.env** out of Git. Then run:

    set -a
    source ./.env
    set +a
    bash scripts/deploy-sepolia.sh

The script deploys a synthetic payment token, the settlement contract, and a narrow agent executor in sequence with explicit gas limits. It stops when any transaction fails, registers a demo invoice, mints test tokens to the payer, and writes public addresses to deployment config files. Copy the resulting public addresses into **ui/config.js** based on **ui/config.example.js**. The connected payer must accept the invoice, approve and fund escrow, and authorize the executor before running the valid and over-limit scenarios.

## Demo recording

The walkthrough has a browser-based player at [Watch the demo](https://rudimentall1.github.io/RWA-Agent-Guardian/video.html). The MP4 is also kept in **demo/** in this repository. The player uses the same video file and supports playback and seeking without requiring a manual download.

The public deployment has already reached its 5,000 dUSD aggregate spending limit. This is the expected final state, so a new settlement preflight on that invoice should return BLOCK. The current deployment is not a resettable sandbox. It predates the latest source hardening; its contracts do not have the new expiry-refund, resolver-rotation, or exact-balance-transfer checks.

## Build and test

Requires Foundry and Solidity 0.8.24.

    forge test -vv

To reproduce the full 2,000 dUSD ALLOW, 3,000 dUSD BLOCK, 5,000 dUSD aggregate-cap, and post-cap BLOCK sequence against fresh local test state, run:

    forge test --match-test testDemoScenarioAllowsTwoThousandBlocksThreeThousandAndStopsAtFiveThousand -vv

See [docs/DEMO_SCENARIO.md](docs/DEMO_SCENARIO.md) for the exact sequence and assertions. This local scenario does not reset or alter the public Sepolia deployment.

## Build provenance

A separate exploratory prototype informed the choice of problem. This repository implements the invoice acceptance, escrow settlement, and dispute lifecycle as a separate codebase, with its own contracts and Foundry tests. The demo uses synthetic assets and does not represent a real receivable or legal claim.
