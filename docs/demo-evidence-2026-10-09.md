# Sepolia demo evidence, 9 October 2026

This note separates the deployment configured by the current GitHub Pages UI from an earlier deployment that has completed settlement transactions. Both are on Sepolia. The token is synthetic demo currency, not a real stablecoin or proof of a legally enforceable receivable.

## Deployment used by the current UI

- UI: https://rudimentall1.github.io/RWA-Agent-Guardian/
- Network: Ethereum Sepolia, chain ID `11155111`
- Invoice ID: `0xe4f729cc5c74e26942b90175714ea77f0711eb25e5ea3b3620ff097d6805a571`
- Token: `0x54ACd743a1733E09c17D011689abA6d53c78bBCA`
- InvoiceSettlement: `0x20Cd7f5c8614b0cb7Ae8353923fE21ff0D66dD35`
- DemoAgentExecutor: `0x84cCC0AF8ab57F531C1adf894CB2C86286f8faB2`
- Payer: `0x1429906b663608DB6aDeAb8F975B47aFbbe8c68C`
- Beneficiary: `0x000000000000000000000000000000000000B0B0`
- Agent owner: `0xD2C8057711a42acC9fD2f4Dd06a262d8652971c2`

At the time this evidence was collected, the values in `deployments-sepolia.json` matched the public `ui/config.js`. Read-only calls confirmed that the configured executor pointed to this settlement and had the configured agent owner. Both onchain contracts remain legacy relative to current `main`: the executor lacks the EIP-712 signed-intent interface, and the settlement lacks the later `ESCALATED` dispute transition. The source fixes are not active at these addresses. AI mode refuses to send through the legacy executor. Use `scripts/deploy-sepolia.sh` to deploy the current settlement and executor as new instances; this does not migrate old state or receipts.

At the time of the check, the invoice was `ACCEPTED`, with `10,000 dUSD` funded and `0 dUSD` paid. The executor mandate was active, with a `2,000 dUSD` per-payment limit, a `5,000 dUSD` aggregate limit, `0 dUSD` spent, and nonce `0`.

Read-only `eth_call` simulations against this deployment returned:

- `2,000 dUSD`, nonce `0`: accepted by the contract's current rules.
- `3,000 dUSD`, nonce `0`: reverted with the contract's policy error because it exceeds the per-payment limit.

These were simulations only. No transaction was broadcast to this deployment during this check, so they do not prove a completed payment.

## Earlier deployment with completed payments

The following transactions belong to a different deployment. They must not be presented as payments made by the contracts configured in the current UI.

- Token: `0x5BbCBE09abAdE15Fbf9a36caB689675F58b50A71`
- InvoiceSettlement: `0x4932eF4E444622F7C85be8CD7c85e0a4D2285885`
- DemoAgentExecutor: `0x0f894f3369D8B9aFfa65fca66B2d3712e829EAE7`
- InvoiceSettlement deployment: https://sepolia.etherscan.io/tx/0xbc77075f8f7e84a44b3e1819bfbfb2107ea17d5933e5735ea423683ee22d08fb
- DemoAgentExecutor deployment: https://sepolia.etherscan.io/tx/0x489dc887df8f99239e95f80e4e951aca89f909d49497f87129b20fbe19852108
- Invoice registration: https://sepolia.etherscan.io/tx/0x8d5bc5df144898f06bc20d99b1c6c1c3f053b5ed2e3a6c33693d122380a43c3c
- Payer token mint: https://sepolia.etherscan.io/tx/0x348c32ccfdabbdccd574f31dac1362959a7d72e807ed6bbabd386df76c2b8bd8
- Settlement of `2,000 dUSD`: https://sepolia.etherscan.io/tx/0xf04e2be3f6f22d59c786b7631505315214266b4214ab524fc0273c4b67d69959
- Settlement of `2,000 dUSD`: https://sepolia.etherscan.io/tx/0xac695defc48e23a2476f62084269ed5b5f3af10bfed896bbee7c78f3ef6a876a
- Settlement of `1,000 dUSD`: https://sepolia.etherscan.io/tx/0x76ade7ebef4aed50e2d1772341bc751865756cdeb9e763a53eb31e8aa8401c4f

All three settlement receipts were independently checked on Sepolia and have status `1`. Read-only calls to the earlier settlement contract show `5,000 dUSD` paid, `5,000 dUSD` remaining in escrow, and the executor mandate at `5,000 dUSD` spent with nonce `3`. This confirms the completed sequence on that earlier deployment only.

## Scope and limitations

- All invoice and token values are synthetic Sepolia test data.
- The prototype has not undergone an independent professional security audit.
- A successful preflight or `eth_call` is not a transaction receipt. For a completed payment, check the receipt, emitted events, and resulting contract state.
- The earlier deployment has different bytecode and addresses. Do not mix its transaction history with the current UI configuration.
