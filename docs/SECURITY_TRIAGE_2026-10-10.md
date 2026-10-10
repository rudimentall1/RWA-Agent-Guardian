# Security triage — 2026-10-10

## Scope and evidence

This is a first-pass triage of the current `main` branch, not an independent audit or a production-readiness certification.

Checks observed during this review:
- Full `forge test -q`: exit code 0.
- `python3 -m unittest discover -s scripts -p 'test*.py' -v`: 53 tests passed.
- `forge test --match-path test/InvoiceSettlement.t.sol -q`: exit code 0.
- Slither: analyzed 4 contracts with 102 detectors and reported 14 results. Slither exited 255 because findings were emitted; this is not equivalent to a compiler/test failure.

The captured Slither output includes the categories below. This triage does not claim that every one of the 14 results is independently exploitable.

## Findings and disposition

| Finding | Classification | Evidence / reasoning | Required follow-up |
|---|---|---|---|
| `reentrancy-balance` in `InvoiceSettlement._transferFromExact` and `_transferExact` | **Not demonstrated exploitable; mitigations present; token trust remains** | The helpers snapshot sender/recipient balances, call ERC-20 `transferFrom`/`transfer`, then check exact balance deltas. External state-changing entry points that call these helpers use the contract's `nonReentrant` modifier. There is also a regression test named `testTokenCallbackCannotReenterSettlement`. Slither's stale-balance warning reflects the intentional before/after accounting pattern; it does not by itself prove an exploitable reentrancy path. | Keep callback regression test; add adversarial-token tests for callbacks, false return values, fee-on-transfer, rebasing, and dishonest `balanceOf`. Explicitly document that arbitrary tokens are not safe merely because exact-delta checks exist. Restrict production deployments to reviewed token contracts. |
| `reentrancy-events` in `DemoAgentExecutor.execute` and `executeWithIntent` | **Informational ordering warning** | Executor events are emitted after the external settlement call. If settlement reverts, the transaction and its events revert together. The warning does not show a state-changing reentrancy exploit by itself. | Keep event semantics documented; consider monitoring settlement events as the canonical on-chain state transition and executor events as supplementary evidence. |
| `timestamp` comparisons in invoice registration, acceptance, mandate authorization, expiry/cancellation, dispute resolution/escalation, matured claims, and settlement | **Boundary-condition review required; not automatically a vulnerability** | These operations intentionally depend on due dates, mandate expiry, settlement deadlines, and a seven-day dispute timeout. Slither's timestamp detector flags comparisons with `block.timestamp`; it does not establish that the conditions are incorrect. | Maintain tests at exact boundary, one second before, and one second after every critical deadline. Check that `DISPUTED` → `ESCALATED` does not unfreeze funds or choose a winner automatically. |

## Confirmed design risk: privileged dispute resolution

This is a trust-model limitation, not a Slither finding.

- `disputeResolverAdmin` is immutable and can replace `disputeResolver`.
- The active resolver can resume execution or cancel/refund a disputed invoice.
- Existing tests cover resolver rotation, resolver-only access, and both resolution outcomes.
- The seven-day timeout escalates the dispute but does not independently arbitrate it or release the funds.

A compromised admin key can therefore appoint a resolver under its control; a compromised resolver can decide the outcome of a disputed invoice. Existing tests prove the permissions work as coded, not that this trust model is suitable for real receivables.

Before real RWA use, require at minimum:
1. Admin and resolver controlled by separate multisigs or similarly independent authorities.
2. A documented, externally reviewable dispute process with notice, evidence, conflicts handling, and appeal.
3. Timelocked resolver changes where operationally feasible, with emergency procedures explicitly documented.
4. Tests for compromised-admin/resolver scenarios and monitoring for resolver-rotation events.
5. Independent contract audit and legal review of the receivable and enforcement model.

## Current go/no-go

**NO-GO for production RWA.** The passing test suites establish regression coverage for tested cases only. They do not prove legal ownership of receivables, enforceability, production operational security, or correctness under all malicious-token and adversarial-dispute scenarios. The demo remains a synthetic-receivable prototype until these gaps are closed and independently reviewed.
