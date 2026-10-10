# Local AI inference evidence, 10 October 2026

## What was tested

The current runner's Ollama decision function was run against a synthetic invoice context on Gensyn2. The test called the local Ollama HTTP API through `scripts/agent_runner.py`; it did not sign an intent, connect to Sepolia, or send any transaction.

Model: `qwen2.5:3b` (local Ollama, CPU-only). The runner used a compact five-field model input, a 256-token context, a 32-token output limit, and four CPU threads. The full invoice, mandate, chain, and address context stays outside the model prompt and is retained separately for the intent evidence.

## Case A: accepted invoice within limits

Synthetic decision facts:

- Invoice status: `ACCEPTED` (2).
- Mandate: active and not expired.
- Computed maximum payment: 2,000 token base units for this fixture.
- Model output: `ALLOW`, amount `2000`, reason code `within_limits`.
- Canonical reason returned by the policy gate: `Within current on-chain caps`.
- Earlier observed inference time: approximately 52 seconds on this CPU-only host.
- Repeat verification against the latest runner source on 10 October: `ALLOW`, amount `2000`, reason `within_limits`; 98.1 seconds end to end on a cold model start, including about 67 seconds to load the model and 29 seconds for the API inference.
- Additional repeat on 10 October using the same `qwen2.5:3b` model and accepted-invoice facts returned `BLOCK`, amount `0`, reason `invoice_not_accepted` after 64.9 seconds. The policy gate rejected this contradiction with `AI reason code contradicts the decision or checked policy facts; no transaction sent`. This repeat only called local inference and the canonical gate; no intent was signed and no RPC or transaction was used.

The model only proposed the decision. The separate gate checked that the status, mandate, deadline and amount agree before the decision can be signed. The repeat verification printed the proposal and canonical reason only; it did not create a signature, write proof evidence, contact Sepolia, or broadcast a transaction.

## Case B: invoice is disputed

Synthetic decision facts were the same except invoice status was changed to `DISPUTED` (3).

- Model output: `BLOCK`, amount `0`, reason code `invoice_not_accepted`.
- Deterministic reason: `Invoice is not accepted`.
- Earlier observed inference time: approximately 10 seconds on this CPU-only host.
- Repeat verification after the model was warm: `BLOCK`, amount `0`, reason `invoice_not_accepted`; 14.0 seconds.

No transaction was sent.

## Fail-closed case: smaller model contradicted the input

The `qwen2.5:0.5b` model returned `BLOCK` with reason code `invoice_not_accepted` even though the synthetic invoice status was `ACCEPTED`, the mandate was active, and the computed maximum was positive. The deterministic gate rejected that combination with:

`AI reason code contradicts the decision or checked policy facts; no transaction sent`

No transaction was sent. This is why the runner defaults to the 3B model rather than 0.5B, and why the model response does not override the policy gate.

## What this proves, and what it does not

This confirms the local model can produce bounded structured proposals on the tested synthetic cases, and that contradictory reason codes are rejected. It is not a full end-to-end payment execution, not an evaluation of model accuracy over a representative dataset, and not proof that the model understands invoices or legal obligations.

These inference tests used a synthetic fixture and were run before any onchain payment flow; they do not imply that the deployed invoice is accepted, funded, or authorized. On 10 October 2026, the public UI was updated to a fresh Sepolia v2 settlement/executor pair, with `SETTLEMENT_VERSION() == 2` and `intentDomainSeparator()` confirmed by read-only RPC calls. The current onchain invoice remains registered but unfunded, and its executor mandate is inactive. See [the deployment evidence](deployment-evidence-2026-10-10.md) for the separate onchain state and receipts.
