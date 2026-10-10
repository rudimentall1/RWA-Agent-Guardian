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
- Deterministic reason shown and signed in the decision record: `Within current on-chain caps`.
- Observed inference time: approximately 52 seconds on this CPU-only host.

The model only proposed the decision. The separate gate checked that the status, mandate, deadline and amount agree before the decision can be signed. This test stopped before signing.

## Case B: invoice is disputed

Synthetic decision facts were the same except invoice status was changed to `DISPUTED` (3).

- Model output: `BLOCK`, amount `0`, reason code `invoice_not_accepted`.
- Deterministic reason: `Invoice is not accepted`.
- Observed inference time: approximately 10 seconds on this CPU-only host.

No transaction was sent.

## Fail-closed case: smaller model contradicted the input

The `qwen2.5:0.5b` model returned `BLOCK` with reason code `invoice_not_accepted` even though the synthetic invoice status was `ACCEPTED`, the mandate was active, and the computed maximum was positive. The deterministic gate rejected that combination with:

`AI reason code contradicts the decision or checked policy facts; no transaction sent`

No transaction was sent. This is why the runner defaults to the 3B model rather than 0.5B, and why the model response does not override the policy gate.

## What this proves, and what it does not

This confirms the local model can produce bounded structured proposals on the tested synthetic cases, and that contradictory reason codes are rejected. It is not a full end-to-end payment execution, not an evaluation of model accuracy over a representative dataset, and not proof that the model understands invoices or legal obligations.

The public UI currently points to legacy Sepolia deployments. The settlement there does not expose `SETTLEMENT_VERSION=2`, and the executor does not expose the signed-intent interface. AI mode should stop during preflight on those addresses. These inference tests do not change or imply anything about the state of deployed contracts.
