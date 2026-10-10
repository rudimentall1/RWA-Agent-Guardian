# Threat model

## Scope

This prototype models invoice registration, acceptance, synthetic-token escrow, issuer attestation, and bounded partial settlement through an executor contract. It is not a production trade-finance system and does not establish that an invoice is legally valid or collectible.

## Assets to protect

- The synthetic ERC-20 balance held by `InvoiceSettlement`.
- Invoice state, funded and paid accounting, and mandate nonce and limits.
- The payer's ability to authorize or revoke an executor.
- The beneficiary address recorded in the invoice terms.
- The integrity of the issuer's signed statement about the invoice fields.

## Trust assumptions

- The deployer/admin controls dispute-resolver rotation. Issuer registration itself is permissionless, but requires a valid signature from the named issuer.
- The issuer's EIP-712 signature is an assertion about the submitted terms and document hash, not a legal opinion or proof of the underlying debt.
- The payer accepts the invoice, funds escrow, and authorizes the executor address.
- The agent runner and its signing key are controlled by the operator. A compromised agent key can spend only within the on-chain mandate, but may spend that allowance maliciously.
- The configured token is expected to be a conventional ERC-20. Exact balance-delta checks reject fee-on-transfer behavior but cannot make arbitrary token implementations safe.

## Controls

- Permissionless issuer registration gated by an EIP-712 signature matching the named issuer.
- EIP-712 invoice attestation binding issuer, invoice ID, payer, beneficiary, token, face value, due date, document hash, nonce, deadline, chain ID, and settlement contract address.
- Per-issuer nonce, signature deadline, canonical low-s ECDSA signature, and onchain attestation digest and signature event for replay protection and auditability.
- Invoice state checks, per-payment and aggregate mandate caps, expiry, execution nonce checks, and escrow-balance checks.
- Exact sender and recipient token balance-delta checks.
- Reentrancy guard around state-changing entry points.
- Regression and invariant tests for `paid <= funded <= faceValue`, escrow coverage, mandate spend limits, valid signatures, invalid signers, and stale issuer nonces.

## Known gaps

- Invoice data and token are synthetic. The document hash is a commitment, not proof of ownership, delivery, enforceability, or asset existence.
- Anyone can publish an invoice statement, so payer review remains essential. EIP-712 proves the named issuer signed the specific terms, but does not independently verify truth or legal due diligence. This repository does not implement an ERC-721 claim token or transfer of legal title.
- A beneficiary claim is available only after the due date plus 30 days and after the latest mandate expiry. Payer refunds are limited to the same grace window.
- Disputes are controlled by a trusted resolver. After seven days, anyone can move a still-unresolved dispute from DISPUTED to ESCALATED, but funds remain frozen. Only the resolver can subsequently resume execution or cancel and refund. There is no bond or neutral arbitration.
- Admin and resolver privileges are centralized; production deployment should use a multisig and a governed delay.
- `scripts/agent_runner.py` supports a local Ollama decision mode and a deterministic compatibility mode. The Ollama mode validates a strict ALLOW/WAIT/BLOCK response against a deterministic maximum, signs the context and decision hashes using EIP-712, and checks the signature against the executor before sending. The upgraded executor verifies the owner signature; `InvoiceSettlement` independently enforces status, mandate, nonce, deadline, escrow and spend caps. The signature proves which key approved those hashes, not that the model reasoned correctly or that an invoice is legally valid.
- The earlier Sepolia deployment used for the recorded three-payment sequence is legacy and remains separate from the current UI deployment. On 2026-10-10, the UI was pointed at a fresh v2 settlement/executor pair; read-only Sepolia calls confirmed `SETTLEMENT_VERSION() == 2`, the executor's `intentDomainSeparator()` interface, and deployed bytecode at both addresses. The current invoice is only registered: it has not yet been accepted, escrow-funded, or paired with an active executor mandate, and no payment is claimed from this deployment. These are testnet instances, not production infrastructure. See [current deployment receipts and checks](deployment-evidence-2026-10-10.md) and [the earlier recorded demo evidence](demo-evidence-2026-10-09.md).
- No independent audit has been performed. Do not use this prototype to hold real assets.
