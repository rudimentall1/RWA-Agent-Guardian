# RWA Evidence and Dispute Requirements

Status: requirements for a future real-receivable integration; not implemented by this prototype.

## 1. What the current on-chain attestation proves

The EIP-712 signature proves that the key corresponding to the recovered issuer address signed the encoded invoice fields and document hash for this chain and contract. It does not prove that:
- the signer is legally authorized to bind the named company;
- the underlying goods or services were delivered and accepted;
- the payer owes the amount under an enforceable contract;
- the receivable has not been assigned, pledged, factored, paid, or submitted elsewhere;
- the document is genuine, complete, or legally enforceable.

A document hash commits to bytes. It does not validate their truth.

## 2. Minimum evidence package before a receivable is eligible

A production integration should require an off-chain evidence package with a stable evidence ID and a content hash for each item:

1. **Invoice document**: original electronic invoice or a verified copy, issuer and payer legal identities, invoice number, issue/due dates, currency, gross/net/tax amounts, line items, and payment instructions.
2. **Underlying contract/order**: contract or purchase-order reference, version, applicable terms, and the legal entity that owes payment.
3. **Performance evidence**: delivery receipt, service acceptance, milestone approval, or other evidence appropriate to the asset class.
4. **Payer confirmation**: an authenticated acceptance tied to the exact invoice ID, amount, currency, beneficiary, and document hash. Acceptance must not be inferred merely from issuer signature.
5. **Issuer authority**: company identity and jurisdiction, a verifiable source for signer authority, key ownership, key validity/revocation state, and a recorded verification timestamp.
6. **Duplicate/encumbrance checks**: invoice-number uniqueness within issuer and payer; searches of available assignment, lien, factoring, financing, and payment records. Record sources, query time, and limitations.
7. **Legal review**: applicable law, assignability, notice/consent requirements, dispute forum, and the evidence needed to enforce the receivable.

Evidence can be confidential. Publish hashes and attestations on-chain; store documents with access controls and preserve an audit trail. A hash without a retrievable, reviewable source document is insufficient for dispute adjudication.

## 3. Roles and attestations

Keep distinct attestations for distinct claims; do not collapse them into a single issuer signature:

- **Issuer**: attests that the invoice and stated terms were issued by it.
- **Payer**: confirms the invoice and acceptance of the stated obligation; this is not a substitute for legal due diligence.
- **Evidence verifier**: records which documents and external sources were checked, by whom, when, and under which verification policy.
- **Servicer/custodian (if applicable)**: attests to payment collection, assignment, and servicing records.
- **Dispute decision-maker**: issues a reasoned outcome under published rules, referring to the evidence IDs considered.

Each attestation should bind the invoice/evidence ID, document hashes, relevant parties, amount/currency, chain and contract domain where on-chain, timestamp, policy version, and signer identity. Include revocation/correction paths; never silently overwrite prior evidence.

## 4. Dispute procedure

Before handling real claims, publish a procedure defining:
- who may raise a dispute and the grounds/deadline;
- notice to both parties and an evidence-submission window;
- how disputed funds are frozen and how unrelated invoices remain unaffected;
- conflict-of-interest rules and replacement of a conflicted decision-maker;
- decision criteria, quorum/appeal process, and a reasoned, auditable outcome;
- timeout behavior that does not automatically award funds to either party;
- emergency key rotation, multisig administration, timelock where appropriate, and a public record of resolver changes.

A resolver's privileged on-chain action is an execution of governance authority, not proof that the underlying dispute was correctly decided. The current prototype has a trusted resolver and privileged resolver admin; it has no neutral arbitration, bond, or independent legal evidence verification.

## 5. Go/no-go gates for real RWA

Do not represent an invoice as a real or financeable receivable until all applicable gates pass:

- legal entity and signer authority verified;
- original invoice and underlying contract reviewed;
- performance/acceptance evidence checked;
- payer confirmation tied to the exact terms;
- duplicate, assignment, lien, and prior-payment checks documented;
- independent dispute procedure and accountable operator established;
- data retention, privacy, sanctions/AML and jurisdiction-specific obligations assessed by qualified counsel;
- independent smart-contract audit and operational key/governance review completed.

## 6. Current project status

This repository currently uses a synthetic invoice and synthetic payment token. The on-chain documentHash is a commitment supplied with the issuer's signed assertion; it is not an implemented document-verification service. No real receivable, legal ownership transfer, or production dispute process is established. These requirements describe the missing integration work; they do not claim it has been built.