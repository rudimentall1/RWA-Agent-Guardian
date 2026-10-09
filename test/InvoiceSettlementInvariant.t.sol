// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/InvoiceSettlement.sol";
import "./TestToken.sol";

interface VmInvariant {
    function prank(address sender) external;
}

contract SettlementHandler {
    InvoiceSettlement public immutable settlement;
    TestToken public immutable token;
    bytes32 public immutable invoiceId;
    uint64 public immutable mandateExpiry;

    constructor(InvoiceSettlement settlement_, TestToken token_, bytes32 invoiceId_, uint64 expiry_) {
        settlement = settlement_;
        token = token_;
        invoiceId = invoiceId_;
        mandateExpiry = expiry_;
    }

    function attemptSettlement(uint128 requested) external {
        InvoiceSettlement.Mandate memory mandate = settlement.getMandate(invoiceId, address(this));
        if (!mandate.active || mandate.nonce == type(uint64).max) return;
        uint128 amount = requested;
        try settlement.settle(invoiceId, amount, mandate.nonce, mandateExpiry) {} catch {}
    }
}

contract InvoiceSettlementInvariantTest {
    VmInvariant private constant vm = VmInvariant(address(uint160(uint256(keccak256("hevm cheat code")))));
    InvoiceSettlement private settlement;
    TestToken private token;
    SettlementHandler private handler;
    bytes32 private constant ID = keccak256("INVARIANT-INVOICE");
    address private constant PAYER = address(0xB0B);
    address private constant BENEFICIARY = address(0xD00D);

    function setUp() public {
        token = new TestToken();
        settlement = new InvoiceSettlement(address(this));
        settlement.setIssuerApproval(address(this), true);
        uint64 dueAt = uint64(block.timestamp + 30 days);
        uint64 expiry = uint64(block.timestamp + 20 days);
        settlement.registerInvoice(ID, PAYER, BENEFICIARY, address(token), 10_000, dueAt, keccak256("invariant-doc"));
        vm.prank(PAYER);
        settlement.acceptInvoice(ID);
        token.mint(PAYER, 10_000);
        vm.prank(PAYER);
        token.approve(address(settlement), 10_000);
        vm.prank(PAYER);
        settlement.fundInvoice(ID, 10_000);
        handler = new SettlementHandler(settlement, token, ID, expiry);
        vm.prank(PAYER);
        settlement.authorizeAgent(ID, address(handler), 2_000, 5_000, expiry);
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_paidNeverExceedsFundedOrFaceValue() public view {
        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(ID);
        require(inv.paid <= inv.funded, "paid exceeds funded");
        require(inv.funded <= inv.faceValue, "funded exceeds face value");
    }

    function invariant_escrowCoversUnpaidFundedBalance() public view {
        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(ID);
        require(token.balanceOf(address(settlement)) >= uint256(inv.funded) - inv.paid, "escrow undercollateralized");
    }

    function invariant_mandateSpendDoesNotExceedTotalLimit() public view {
        InvoiceSettlement.Mandate memory mandate = settlement.getMandate(ID, address(handler));
        require(mandate.spent <= mandate.totalLimit, "mandate overspent");
    }
}
