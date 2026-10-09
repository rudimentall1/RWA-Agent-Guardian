# Threat model

## Scope

This prototype models invoice acceptance, synthetic-token escrow, and bounded partial settlement through an executor contract. It is not a production trade-finance system and does not establish that an invoice is legally valid or collectible.

## Assets to protect

- The synthetic ERC-20 balance held by `InvoiceSettlement`.
- Invoice state, funded and paid accounting, and mandate nonce/limits.
- The payer's ability to authorize or revoke an executor.
- The beneficiary address recorded in invoice terms.

## Trust assumptions

- The deployer/admin controls the issuer allowlist and dispute-resolver rotation.
- The dispute resolver is trusted to resolve disputes honestly; the prototype has no timeout or decentralized arbitration.
- The payer accepts the invoice, funds escrow, and authorizes the executor address.
- The agent runner and its private key are controlled by the operator. A compromised agent key can spend only within the on-chain mandate, but may spend that allowance maliciously.
- The configured token is expected to be a conventional ERC-20; exact balance-delta checks reject fee-on-transfer behavior but cannot make arbitrary token implementations safe.

## Controls

- Invoice issuer allowlist controlled by the settlement admin.
- Invoice state checks, per-payment and aggregate mandate caps, expiry, nonce checks, and escrow-balance checks.
- Exact sender/recipient token balance-delta checks.
- Reentrancy guard around state-changing external entry points.
- Regression and invariant tests for `paid <= funded <= faceValue`, escrow coverage, and mandate spend limits.

## Known gaps

- Invoice data and token are synthetic. The document hash is a commitment, not proof of ownership, delivery, or legal enforceability.
- Issuer approval is an admin-managed allowlist, not an independent attestation or legal due diligence. A beneficiary claim is only available after due date plus 30 days and after the latest mandate expiry; the payer refund path is restricted to the same grace window.
- Disputes are controlled by a trusted resolver. After seven days, anyone can reopen the invoice; this avoids an indefinite technical freeze but does not decide the underlying commercial dispute. There is no bond or neutral arbitration.
- Admin and resolver privileges are centralized; production deployment should use a multisig and a governed delay.
- The demo executor is not itself an AI model. `scripts/agent_runner.py` is a deterministic off-chain scheduler that submits only on-chain-authorized executions.
- The already deployed Sepolia contracts do not gain these source changes unless a new deployment is made and verified.
- No independent audit has been performed. Do not use this prototype to hold real assets.
