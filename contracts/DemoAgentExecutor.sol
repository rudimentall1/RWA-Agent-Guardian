// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./InvoiceSettlement.sol";

/// @notice Narrow executor with an EIP-712-verifiable AI-agent intent path.
/// @dev The model is not trusted to enforce limits. InvoiceSettlement remains the final policy gate.
contract DemoAgentExecutor {
    InvoiceSettlement public immutable settlement;
    address public immutable owner;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant INTENT_TYPEHASH = keccak256(
        "AgentIntent(bytes32 invoiceId,uint128 amount,uint64 nonce,uint64 deadline,bytes32 contextHash,bytes32 decisionHash)"
    );
    uint256 private constant SECP256K1N_HALF =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    error Unauthorized();
    error InvalidIntentSignature();

    event ExecutionRequested(bytes32 indexed invoiceId, uint256 amount, uint64 nonce);
    event AgentIntentExecuted(
        bytes32 indexed invoiceId,
        address indexed signer,
        bytes32 indexed intentDigest,
        uint128 amount,
        uint64 nonce,
        uint64 deadline,
        bytes32 contextHash,
        bytes32 decisionHash
    );

    constructor(address settlement_, address owner_) {
        if (settlement_ == address(0) || owner_ == address(0)) revert Unauthorized();
        settlement = InvoiceSettlement(settlement_);
        owner = owner_;
    }

    /// @notice Legacy execution path retained for the existing deployed demo.
    function execute(bytes32 invoiceId, uint128 amount, uint64 nonce, uint64 deadline) external {
        if (msg.sender != owner) revert Unauthorized();
        settlement.settle(invoiceId, amount, nonce, deadline);
        emit ExecutionRequested(invoiceId, amount, nonce);
    }

    function intentDomainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("RWA Agent Guardian Executor")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function intentDigest(
        bytes32 invoiceId,
        uint128 amount,
        uint64 nonce,
        uint64 deadline,
        bytes32 contextHash,
        bytes32 decisionHash
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(INTENT_TYPEHASH, invoiceId, amount, nonce, deadline, contextHash, decisionHash)
        );
        return keccak256(abi.encodePacked(hex"1901", intentDomainSeparator(), structHash));
    }

    /// @notice Publicly verifiable signature check for an intent under this executor's EIP-712 domain.
    function verifyIntent(
        bytes32 invoiceId,
        uint128 amount,
        uint64 nonce,
        uint64 deadline,
        bytes32 contextHash,
        bytes32 decisionHash,
        bytes calldata signature
    ) external view returns (bool) {
        return _recoverSigner(
            intentDigest(invoiceId, amount, nonce, deadline, contextHash, decisionHash), signature
        ) == owner;
    }

    /// @notice Executes an owner-signed intent; any caller may relay it without changing its terms.
    function executeWithIntent(
        bytes32 invoiceId,
        uint128 amount,
        uint64 nonce,
        uint64 deadline,
        bytes32 contextHash,
        bytes32 decisionHash,
        bytes calldata signature
    ) external {
        bytes32 digest = intentDigest(invoiceId, amount, nonce, deadline, contextHash, decisionHash);
        if (_recoverSigner(digest, signature) != owner) revert InvalidIntentSignature();

        // Settlement independently enforces status, mandate, nonce, deadline, escrow and spend caps.
        settlement.settle(invoiceId, amount, nonce, deadline);
        emit AgentIntentExecuted(
            invoiceId, owner, digest, amount, nonce, deadline, contextHash, decisionHash
        );
    }

    function _recoverSigner(bytes32 digest, bytes calldata signature) private pure returns (address signer) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 sigS;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            sigS := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (uint256(sigS) > SECP256K1N_HALF || (v != 27 && v != 28)) return address(0);
        signer = ecrecover(digest, v, r, sigS);
    }
}
