// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./InvoiceSettlement.sol";

/// @notice Narrow demo agent adapter. It cannot choose a target or arbitrary calldata.
contract DemoAgentExecutor {
    InvoiceSettlement public immutable settlement;
    address public immutable owner;

    error Unauthorized();

    event ExecutionRequested(bytes32 indexed invoiceId, uint256 amount, uint64 nonce);

    constructor(address settlement_, address owner_) {
        if (settlement_ == address(0) || owner_ == address(0)) revert Unauthorized();
        settlement = InvoiceSettlement(settlement_);
        owner = owner_;
    }

    function execute(bytes32 invoiceId, uint128 amount, uint64 nonce, uint64 deadline) external {
        if (msg.sender != owner) revert Unauthorized();
        settlement.settle(invoiceId, amount, nonce, deadline);
        emit ExecutionRequested(invoiceId, amount, nonce);
    }
}
