# RWA Agent Guardian

**Escrow settlement for agent-operated invoice payments.**

The prototype models a narrow, testable trade-finance flow: an issuer registers an invoice commitment, the payer accepts it, funds are deposited into escrow, and a payer-authorized agent can make capped partial payments to the named beneficiary.

The key rule is about invoice state, not just wallet balance: an agent cannot settle an unaccepted or disputed invoice. Each mandate has a per-payment cap, an aggregate cap, an expiry, and a monotonic nonce. A failed token transfer reverts the state change. A dispute resolver can resume the invoice or cancel it and refund the unpaid escrow balance.

## Current scope

- One Solidity settlement contract, a synthetic ERC-20 payment token, and a narrow agent executor.
- A separate test-only token fixture.
- A synthetic invoice record bound to a terms hash, payer, beneficiary, payment token, face value, and due date.
- Explicit lifecycle: REGISTERED to ACCEPTED to DISPUTED / SETTLED / CANCELLED.
- Payer-controlled agent authorization, revocation, per-payment and aggregate limits.
- Partial settlement, nonce/deadline checks, escrow accounting, late settlement under a still-valid mandate, and dispute freeze.
- Foundry tests for allowed settlement and important failure paths.

## Important limitations

This is a hackathon prototype, not an audited financial product. The invoice and payment token used for tests are synthetic; no real receivable, legal ownership claim, or regulated asset is represented. The dispute resolver is a trusted role in this MVP and would need a real governance/dispute process in production.

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

## Build and test

Requires Foundry and Solidity 0.8.24.

    forge test -vv

## Build provenance

A separate exploratory prototype existed before the official sprint and informed the choice of problem. This repository is a new implementation focused on escrow settlement, buyer acceptance, and dispute-state enforcement; its source and tests are being written during the sprint rather than copied from that prototype. Because the event rules exclude substantially pre-built solutions, eligibility should be confirmed with the organizers before final submission.
