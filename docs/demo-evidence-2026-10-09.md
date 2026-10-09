# RWA-Agent-Guardian — demo evidence (2026-10-09)

This note records the Sepolia demo state observed during the hackathon walkthrough. It is evidence of a testnet prototype run, not a security audit or a claim about real-world assets.

## Public demo

- UI: https://rudimentall1.github.io/RWA-Agent-Guardian/
- Network: Ethereum Sepolia (chain ID `11155111`)
- Invoice: `INV-1001`
- Invoice face value: `10,000 dUSD` (synthetic demo token)
- Payer: `0x1429906b663608DB6aDeAb8F975B47aFbbe8c68C`
- Beneficiary: `0x000000000000000000000000000000000000b0b0`
- Agent executor: `0x29a88F9571295ab5685f4DDc0C7D63dDC26f8c28`
- Mandate shown in UI: `2,000 dUSD` maximum per payment, `5,000 dUSD` cumulative cap, 7-day expiry.

## Observed checks

- Preflight for `2,000 dUSD`: `ALLOW`; the UI states no transaction is sent by preflight.
- Preflight for `3,000 dUSD`: `BLOCK`; the UI states wallet signing was not requested and the onchain simulation reverted.
- After settlement activity, the UI showed `Already paid: 4,000 dUSD`.
- Latest supplied UI state showed `Already paid: 5,000 dUSD`, `Escrow funded: 10,000 dUSD`, `Token balance: 0 dUSD`, invoice state `ACCEPTED`, and a further `3,000 dUSD` attack simulation returning `BLOCK`.

These are UI-observed states supplied during the demo walkthrough. Transaction-to-amount mapping and receipt details should be independently checked on Etherscan before using this note as a formal test report.

## Transaction links supplied during the walkthrough

- Invoice registration: https://sepolia.etherscan.io/tx/0x5e61c2b6424ef057711344d470c5ff25369894a2c745e411e1bd8c13df134f47
- Token mint: https://sepolia.etherscan.io/tx/0xe546aeeb306072bf2c277aeb243dd7f58998da66659dc5e28a6866e30b438242
- Other supplied transaction: https://sepolia.etherscan.io/tx/0xc2b614b6110688c1a3eec7eb894f78660fb5e2a7b894499771787655cada7c8d
- Other supplied transaction: https://sepolia.etherscan.io/tx/0xf19743b92c69699aa0f52950ee4ea76aa7f19bd7fc029a4602fbc0c274a77bd1
- Other supplied transaction: https://sepolia.etherscan.io/tx/0x2b5881f305b15748c2b56353b148f458c75f379d63b4615c1abd734ba86ce41e
- Other supplied transaction: https://sepolia.etherscan.io/tx/0x170aefe3d846390fc48c5231ff8a3bb290167f2daadf4fec6e3a5a3bf16ee8cb
- Preflight-related transaction link supplied by user: https://sepolia.etherscan.io/tx/0x8d090a6987454e024ac01d7dd1a5b9edb4b91015f6135cc313344ae37a9115f9
- Settlement-related transaction link supplied by user: https://sepolia.etherscan.io/tx/0xc0d68c7571af4671dd5549f29708290826ead49f51d253aa39d6bc0d5f75ad28
- Latest transaction link supplied with the `5,000 dUSD` UI state: https://sepolia.etherscan.io/tx/0xe7af7eb08274dd0573ba13b23a8c740ce05c2813ab70d9efcea8de44cb5cb7dd

## Scope and limitations

- dUSD and invoice data are synthetic Sepolia fixtures, not a real stablecoin, legal receivable, or evidence of regulated asset ownership.
- This prototype is unaudited.
- A preflight `ALLOW` is not a settlement receipt; verify transaction status, emitted events, and resulting contract state separately.
- A reverted simulation confirms a rejection, but its exact reason should be decoded from the contract error before attributing it to a specific guard.
