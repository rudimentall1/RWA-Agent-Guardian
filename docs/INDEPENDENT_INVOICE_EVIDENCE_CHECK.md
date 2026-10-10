# Independent invoice evidence comparison

`scripts/invoice_evidence_verifier.py` compares AI-extracted candidate fields with a separate JSON evidence record. It is deliberately a consistency checker, not a payment oracle.

## Run

First create the extraction artifact using `scripts/invoice_evidence_extractor.py`. Then prepare an evidence JSON from independently controlled sources (the script does not fetch or authenticate those sources):

```json
{
  "invoice_number": "INV-42",
  "issuer_name": "Supplier Ltd",
  "debtor_name": "Buyer Ltd",
  "currency": "EUR",
  "total_amount_text": "2000.00",
  "issue_date": "2026-10-01",
  "due_date": "2026-11-01",
  "accepted": true,
  "accepted_invoice_sha256": "<SHA-256 of the exact original invoice bytes>",
  "duplicate_check_clear": true,
  "encumbrance_check_clear": true
}
```

```bash
python3 scripts/invoice_evidence_verifier.py \
  --extraction artifacts/invoice-extraction-latest.json \
  --evidence /path/to/independent-evidence.json \
  --output artifacts/invoice-evidence-check-latest.json
```

The verifier requires exact string matches for the listed fields to avoid silently normalizing away ambiguity. The acceptance record must bind to the exact source hash. Evidence fields are assertions supplied by the caller; this tool does not verify signatures, issuer authority, on-chain state, delivery, liens, or whether a duplicate-check provider is trustworthy.

## Interpret the status

- `CONSISTENT`: all supplied required values agree. This is **not** proof the invoice is genuine or enforceable.
- `MISMATCH`: a field mismatch or required safety condition failed.
- `INCOMPLETE`: one or more required independent evidence fields are missing.

Every result sets `paymentAuthorization: false`. Do not connect this report directly to the executor. A production flow needs authenticated evidence adapters, signed acceptance bound to the document hash, authoritative registry/assignment checks, delivery evidence, and independent security/legal review.
