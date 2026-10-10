# Sepolia deployment evidence — 2026-10-10

This is the fresh deployment configured by the public browser demo. It is separate from the earlier Sepolia addresses and payment receipts; do not combine their histories.

- Network: Ethereum Sepolia, chain ID `11155111`
- Deployer: `0xf247B3365269735FEc42054bE90Ee570AAcD6cb3`
- Synthetic payer: `0x1429906b663608DB6aDeAb8F975B47aFbbe8c68C`
- Beneficiary: `0x000000000000000000000000000000000000B0B0`
- Agent owner: `0xD2C8057711a42acC9fD2f4Dd06a262d8652971c2`

## Contracts and deployment receipts

Every transaction below was checked against Sepolia RPC and returned receipt status `1`.

| Action | Address or transaction | Block |
|---|---|---:|
| Deploy `DemoSettlementToken` | [Contract](https://sepolia.etherscan.io/address/0x8648a0aC53eEBBBd2297166964fa1E468703394D) · [deployment tx](https://sepolia.etherscan.io/tx/0x7cb9e3841a6db130e95083ad250289c473d1972a0f61933b1ef0b0403a18e3dc) | 11882499 |
| Deploy `InvoiceSettlement` | [Contract](https://sepolia.etherscan.io/address/0x1Ab2f11414C3db48C532B77e23ddf5Cd272ce9dE) · [deployment tx](https://sepolia.etherscan.io/tx/0xbe1e6db0885b7f366b03fa081912ee10ccba5765ed3219064a10ca5cbd9048d0) | 11882500 |
| Register the synthetic invoice with issuer EIP-712 attestation | [transaction](https://sepolia.etherscan.io/tx/0xa8519fbe7c2eb24e8534d8f9df7225af38c32e42a842b5935f2e0afdc53aa84f) | 11882501 |
| Deploy `DemoAgentExecutor` | [Contract](https://sepolia.etherscan.io/address/0xa40F503648e991609FFF19967a1f7378468437f2) · [deployment tx](https://sepolia.etherscan.io/tx/0xb725ea1bc952025601d7142c61cf84b9eac3b2012c3cf6dc6b8a7d4977851e4e) | 11882502 |
| Mint demo tokens to the payer | [transaction](https://sepolia.etherscan.io/tx/0x8e4ac0fe2e23e0c09a0aac3c073b07bd3dd9ba348bb5e7242e3356d4f5de94c8) | 11882503 |

## Invoice record

- Invoice ID: `0xe4f729cc5c74e26942b90175714ea77f0711eb25e5ea3b3620ff097d6805a571`
- Terms hash: `0xf10ff944571cece09b68517b12f92ee7bbaba02e0ec1cb3de93febeb48a69c61`
- Contract due timestamp: `1794202848`
- The deployment script registered the invoice and minted the payer's synthetic token balance. That is **not** the same as accepting the invoice, funding escrow, authorizing the executor, or executing a payment.

## Post-deployment checks

Read-only Sepolia calls after deployment confirmed:

- `InvoiceSettlement.SETTLEMENT_VERSION()` returns `2`.
- `DemoAgentExecutor.intentDomainSeparator()` returns `0xf842129155f001b246906a9bc29244696a36c6b616a42d63270f40a71f2c8a63`.
- Bytecode exists at all three contract addresses.
- The live GitHub Pages config points to these addresses.

The payer still needs to connect the payer wallet in the browser demo, accept the invoice, approve/fund the settlement escrow, and authorize the executor before a payment can execute. No payment execution is claimed by this deployment record. The older deployments and their receipts remain separate historical evidence.
