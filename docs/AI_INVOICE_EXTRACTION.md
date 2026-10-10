# AI invoice claim extraction prototype

`scripts/invoice_evidence_extractor.py` is a separate, untrusted extraction stage. It accepts UTF-8 text extracted from an invoice, asks local Ollama for structured candidate fields, and writes a JSON artifact containing the source SHA-256 and explicit trust-boundary metadata.

## Run

```bash
python3 scripts/invoice_evidence_extractor.py \
  --input /path/to/invoice-text.txt \
  --output artifacts/invoice-extraction-latest.json \
  --model qwen2.5:3b
```

PDF parsing and OCR are deliberately not hidden inside this script. Convert the source to text through a separately reviewable step, preserve the original document, and hash the original bytes as well as any extracted text in a production evidence pipeline.

## What the model does

- Extracts invoice number, issuer/debtor names, currency, amount/date strings, line items, payment terms, and uncertainty notes.
- Uses `null` for missing fields and preserves amount/date text instead of silently normalizing it.
- Treats the document as untrusted data, not as instructions.
- Does **not** determine authenticity, acceptance, ownership, payment status, legal enforceability, or eligibility.
- Does **not** sign an intent, call a wallet, authorize payment, or broadcast a transaction.

The output is marked `UNVERIFIED_CLAIMS` and `paymentAuthorization: false`. It is not an oracle or a proof that the invoice is genuine. The claim fields must be independently checked against issuer identity and authority, debtor acceptance bound to the exact document hash, the underlying contract and delivery/performance evidence, amount reconciliation, duplicate financing/assignment and liens, and legal requirements.

## Validation status

Three offline unit tests passed on Gensyn2. A live Ollama smoke test against a clearly synthetic plain-text invoice was also launched; its extracted fields must be reviewed before treating the test as successful. A single synthetic document is a plumbing test, not an accuracy benchmark.

## Relationship to the payment agent

The existing payment decision model remains unreliable in the repeated test: it proposed `ALLOW` for an unaccepted invoice and used `invoice_not_accepted` as the reason for unrelated cases. The deterministic gate blocked those proposals. Do not route extraction output directly into authorization. The next integration step is to compare extracted claims with independently obtained on-chain and documentary facts, report mismatches, and keep the policy gate—not the model—in charge of authorization.
