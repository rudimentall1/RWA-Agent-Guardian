# RWA-Agent-Guardian - demo evidence (2026-10-09)

This note records the currently configured Sepolia demo and the contract state read directly from the RPC. It describes a testnet prototype, not an audit or a claim about real-world assets.

## Public demo

- UI: https://rudimentall1.github.io/RWA-Agent-Guardian/
- Network: Ethereum Sepolia (chain ID `11155111`)
- Invoice ID: `0xe4f729cc5c74e26942b90175714ea77f0711eb25e5ea3b3620ff097d6805a571`
- Invoice face value: `10,000 dUSD` (synthetic demo token; 6 decimals)
- Token: `0x5BbCBE09abAdE15Fbf9a36caB689675F58b50A71`
- InvoiceSettlement: `0x4932eF4E444622F7C85be8CD7c85e0a4D2285885`
- DemoAgentExecutor: `0x0f894f3369D8B9aFfa65fca66B2d3712e829EAE7`
- Payer: `0x1429906b663608DB6aDeAb8F975B47aFbbe8c68C`
- Beneficiary: `0x000000000000000000000000000000000000b0b0`

## State read from Sepolia RPC

At the time of this check:

- Invoice status: `ACCEPTED`.
- Escrow funded: `10,000 dUSD`.
- Settled: `5,000 dUSD`.
- Token balance held by the settlement contract: `5,000 dUSD`.
- Payer token balance: `0 dUSD`.
- Executor mandate: active; per-payment cap `2,000 dUSD`; aggregate cap `5,000 dUSD`; spent `5,000 dUSD`.
- The public demo configuration matches the contract addresses above.

These are current contract-state reads, not a substitute for inspecting individual transaction receipts. The expected scenario is: preflight `2,000 dUSD` to ALLOW; preflight `3,000 dUSD` to BLOCK; execute permitted settlements up to the `5,000 dUSD` aggregate cap; then a further attempt to BLOCK.

## Known transaction records for the current deployment

- InvoiceSettlement deployment: https://sepolia.etherscan.io/tx/0xbc77075f8f7e84a44b3e1819bfbfb2107ea17d5933e5735ea423683ee22d08fb
- DemoAgentExecutor deployment: https://sepolia.etherscan.io/tx/0x489dc887df8f99239e95f80e4e951aca89f909d49497f87129b20fbe19852108
- Invoice registration: https://sepolia.etherscan.io/tx/0x8d5bc5df144898f06bc20d99b1c6c1c3f053b5ed2e3a6c33693d122380a43c3c
- Payer token mint: https://sepolia.etherscan.io/tx/0x348c32ccfdabbdccd574f31dac1362959a7d72e807ed6bbabd386df76c2b8bd8
- Settlement of 2,000 dUSD: https://sepolia.etherscan.io/tx/0xf04e2be3f6f22d59c786b7631505315214266b4214ab524fc0273c4b67d69959
- Settlement of 2,000 dUSD: https://sepolia.etherscan.io/tx/0xac695defc48e23a2476f62084269ed5b5f3af10bfed896bbee7c78f3ef6a876a
- Settlement of 1,000 dUSD: https://sepolia.etherscan.io/tx/0x76ade7ebef4aed50e2d1772341bc751865756cdeb9e763a53eb31e8aa8401c4f

The three settlement transaction receipts have status 1 on Sepolia. The aggregate-cap rejection is a read-only simulation and has no transaction hash because it is not broadcast.

Only transaction records identified for this deployment are listed here. Do not attribute records from the earlier contract deployment to the current contracts.

## Scope and limitations

- dUSD and invoice data are synthetic Sepolia fixtures, not a real stablecoin, legal receivable, or evidence of regulated asset ownership.
- This prototype is unaudited.
- A preflight `ALLOW` is not a settlement receipt; verify transaction status, emitted events, and resulting contract state separately.
- A reverted simulation confirms rejection, but its exact reason should be decoded from the contract error before attributing it to a specific guard.
