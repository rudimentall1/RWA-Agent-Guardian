# RWA Agent Guardian

**Escrow settlement for agent-operated invoice payments.**

The prototype models a narrow, testable trade-finance flow: an issuer registers an invoice commitment, the payer accepts it, funds are deposited into escrow, and a payer-authorized agent can make capped partial payments to the named beneficiary.

The key rule is about invoice state, not just wallet balance: an agent cannot settle an unaccepted or disputed invoice. Each mandate has a per-payment cap, an aggregate cap, an expiry, and a monotonic nonce. A failed token transfer reverts the state change. A dispute resolver can resume the invoice or cancel it and refund the unpaid escrow balance.

## Current scope

- One Solidity settlement contract and an ERC-20-compatible test token.
- A synthetic invoice record bound to a terms hash, payer, beneficiary, payment token, face value, and due date.
- Explicit lifecycle: REGISTERED → ACCEPTED → DISPUTED / SETTLED / CANCELLED.
- Payer-controlled agent authorization, revocation, per-payment and aggregate limits.
- Partial settlement, nonce/deadline checks, escrow accounting, late settlement under a still-valid mandate, and dispute freeze.
- Foundry tests for allowed settlement and important failure paths.

## Important limitations

This is a hackathon prototype, not an audited financial product. The invoice and payment token used for tests are synthetic; no real receivable, legal ownership claim, or regulated asset is represented. The dispute resolver is a trusted role in this MVP and would need a real governance/dispute process in production.

## Build and test

Requires Foundry and Solidity 0.8.24.

    forge test -vv

## Build provenance

A separate exploratory prototype existed before the official sprint and informed the choice of problem. This repository is a new implementation focused on escrow settlement, buyer acceptance, and dispute-state enforcement; its source and tests are being written during the sprint rather than copied from that prototype. Because the event rules exclude substantially pre-built solutions, eligibility should be confirmed with the organizers before final submission.
