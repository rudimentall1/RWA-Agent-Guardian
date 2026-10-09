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
- Disputes are controlled by a trusted resolver. After seven days, anyone can reopen the invoice; this prevents an indefinite technical freeze but does not decide the underlying commercial dispute. There is no bond or neutral arbitration.
- Admin and resolver privileges are centralized; production deployment should use a multisig and a governed delay.
- The executor is not an AI model. `scripts/agent_runner.py` is a deterministic offchain scheduler that submits only onchain-authorized executions.
- The existing public Sepolia contracts predate the current source and do not gain these changes unless a fresh deployment is made and verified.
- No independent audit has been performed. Do not use this prototype to hold real assets.
