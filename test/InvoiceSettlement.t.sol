// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/InvoiceSettlement.sol";
import "../contracts/DemoAgentExecutor.sol";
import "./TestToken.sol";

interface Vm {
    function prank(address sender) external;
    function warp(uint256 timestamp) external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata revertData) external;
}

contract InvoiceSettlementTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant INVOICE_ID = keccak256("INV-2026-001");
    bytes32 private constant TERMS_HASH = keccak256("synthetic-invoice-terms-v1");
    address private constant PAYER = address(0xB0B);
    address private constant BENEFICIARY = address(0xD00D);
    address private constant AGENT = address(0xA11CE);
    address private constant STRANGER = address(0xBAD);

    TestToken private token;
    InvoiceSettlement private settlement;
    uint64 private dueAt;
    uint64 private mandateExpiry;

    function setUp() public {
        token = new TestToken();
        settlement = new InvoiceSettlement(address(this));
        dueAt = uint64(block.timestamp + 30 days);
        mandateExpiry = uint64(block.timestamp + 1 days);

        token.mint(PAYER, 10_000);
        vm.prank(PAYER);
        token.approve(address(settlement), 10_000);

        settlement.registerInvoice(INVOICE_ID, PAYER, BENEFICIARY, address(token), 10_000, dueAt, TERMS_HASH);
        vm.prank(PAYER);
        settlement.acceptInvoice(INVOICE_ID);
        vm.prank(PAYER);
        settlement.fundInvoice(INVOICE_ID, 10_000);
        vm.prank(PAYER);
        settlement.authorizeAgent(INVOICE_ID, AGENT, 2_000, 5_000, mandateExpiry);
    }

    function testDemoExecutorCanSettleWhenItsAddressHasAMandate() public {
        DemoAgentExecutor executor = new DemoAgentExecutor(address(settlement), PAYER);
        vm.prank(PAYER);
        settlement.authorizeAgent(INVOICE_ID, address(executor), 2_000, 5_000, mandateExpiry);

        vm.prank(PAYER);
        executor.execute(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.paid == 2_000, "executor settlement not recorded");
        require(token.balanceOf(BENEFICIARY) == 2_000, "beneficiary not paid");
    }

    function testDemoExecutorRejectsCallsFromNonOwner() public {
        DemoAgentExecutor executor = new DemoAgentExecutor(address(settlement), PAYER);
        vm.expectRevert(DemoAgentExecutor.Unauthorized.selector);
        vm.prank(STRANGER);
        executor.execute(INVOICE_ID, 1_000, 0, uint64(block.timestamp + 1 hours));
    }

    function testAgentCanMakeAuthorizedPartialSettlement() public {
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        InvoiceSettlement.Mandate memory mandate = settlement.getMandate(INVOICE_ID, AGENT);
        require(token.balanceOf(BENEFICIARY) == 2_000, "beneficiary payment mismatch");
        require(inv.paid == 2_000, "paid amount mismatch");
        require(inv.status == InvoiceSettlement.Status.ACCEPTED, "partial payment changed status");
        require(mandate.spent == 2_000 && mandate.nonce == 1, "mandate state mismatch");
    }

    function testPerPaymentLimitIsEnforced() public {
        vm.expectRevert(InvoiceSettlement.AgentLimitExceeded.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_001, 0, uint64(block.timestamp + 1 hours));
    }

    function testAggregateLimitIsEnforcedAcrossPartialPayments() public {
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 1, uint64(block.timestamp + 1 hours));

        vm.expectRevert(InvoiceSettlement.AgentLimitExceeded.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_001, 2, uint64(block.timestamp + 1 hours));
    }

    function testReplayOrWrongNonceIsRejected() public {
        vm.expectRevert(InvoiceSettlement.InvalidNonce.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 1, uint64(block.timestamp + 1 hours));
    }

    function testRevokedAgentCannotSettle() public {
        vm.prank(PAYER);
        settlement.revokeAgent(INVOICE_ID, AGENT);

        vm.expectRevert(InvoiceSettlement.InvalidAgent.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 0, uint64(block.timestamp + 1 hours));
    }

    function testExpiredMandateCannotSettle() public {
        vm.warp(uint256(mandateExpiry) + 1);

        vm.expectRevert(InvoiceSettlement.InvalidAgent.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 0, uint64(block.timestamp + 1 hours));
    }

    function testExecutionDeadlineCannotOutliveMandate() public {
        vm.expectRevert(InvoiceSettlement.InvalidDeadline.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 0, mandateExpiry + 1);
    }

    function testExpiredExecutionDeadlineIsRejected() public {
        vm.expectRevert(InvoiceSettlement.InvalidDeadline.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 0, uint64(block.timestamp - 1));
    }

    function testReauthorizationDoesNotResetSpentOrNonce() public {
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));

        vm.prank(PAYER);
        settlement.authorizeAgent(INVOICE_ID, AGENT, 2_000, 5_000, mandateExpiry);

        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 1, uint64(block.timestamp + 1 hours));

        InvoiceSettlement.Mandate memory mandate = settlement.getMandate(INVOICE_ID, AGENT);
        require(mandate.spent == 4_000 && mandate.nonce == 2, "reauthorization reset mandate");
    }

    function testTotalLimitCannotBeLoweredBelowAlreadySpent() public {
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));

        vm.expectRevert(InvoiceSettlement.AgentLimitExceeded.selector);
        vm.prank(PAYER);
        settlement.authorizeAgent(INVOICE_ID, AGENT, 1_000, 1_000, mandateExpiry);
    }

    function testUnapprovedCallerCannotSettle() public {
        vm.expectRevert(InvoiceSettlement.InvalidAgent.selector);
        vm.prank(STRANGER);
        settlement.settle(INVOICE_ID, 1_000, 0, uint64(block.timestamp + 1 hours));
    }

    function testSettlementCanRunAfterMaturityWhileMandateIsStillValid() public {
        vm.prank(PAYER);
        settlement.authorizeAgent(INVOICE_ID, AGENT, 2_000, 5_000, uint64(block.timestamp + 60 days));

        vm.warp(uint256(dueAt) + 1);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 0, uint64(block.timestamp + 1 hours));

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.paid == 1_000, "late settlement did not execute");
        require(token.balanceOf(BENEFICIARY) == 1_000, "beneficiary not paid");
    }

    function testDisputeFreezesAgentSettlement() public {
        vm.prank(PAYER);
        settlement.disputeInvoice(INVOICE_ID);

        vm.expectRevert(InvoiceSettlement.WrongStatus.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 0, uint64(block.timestamp + 1 hours));
    }

    function testResolverCanCancelAndRefundUnpaidEscrow() public {
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));
        vm.prank(PAYER);
        settlement.disputeInvoice(INVOICE_ID);

        settlement.resolveDispute(INVOICE_ID, false);

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.status == InvoiceSettlement.Status.CANCELLED, "invoice not cancelled");
        require(token.balanceOf(PAYER) == 8_000, "remaining escrow not refunded");
        require(token.balanceOf(address(settlement)) == 0, "escrow should be empty");
    }

    function testOnlyResolverCanResolveDispute() public {
        vm.prank(PAYER);
        settlement.disputeInvoice(INVOICE_ID);

        vm.expectRevert(InvoiceSettlement.Unauthorized.selector);
        vm.prank(STRANGER);
        settlement.resolveDispute(INVOICE_ID, true);
    }

    function testTokenFailureRollsBackPaymentAndMandateState() public {
        token.setFailTransfers(true);

        vm.expectRevert(InvoiceSettlement.TransferFailed.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 0, uint64(block.timestamp + 1 hours));

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        InvoiceSettlement.Mandate memory mandate = settlement.getMandate(INVOICE_ID, AGENT);
        require(inv.paid == 0, "paid amount must roll back");
        require(mandate.spent == 0 && mandate.nonce == 0, "mandate must roll back");
    }

    function testCannotFundAboveFaceValue() public {
        vm.expectRevert(InvoiceSettlement.InvalidAmount.selector);
        vm.prank(PAYER);
        settlement.fundInvoice(INVOICE_ID, 1);
    }

    function testOnlyPayerCanAuthorizeAgent() public {
        vm.expectRevert(InvoiceSettlement.Unauthorized.selector);
        vm.prank(STRANGER);
        settlement.authorizeAgent(INVOICE_ID, STRANGER, 100, 500, mandateExpiry);
    }

    function testInvoiceMustBeAcceptedBeforeFunding() public {
        bytes32 otherId = keccak256("INV-UNACCEPTED");
        settlement.registerInvoice(
            otherId,
            PAYER,
            BENEFICIARY,
            address(token),
            1_000,
            uint64(block.timestamp + 30 days),
            keccak256("other-terms")
        );

        vm.expectRevert(InvoiceSettlement.WrongStatus.selector);
        vm.prank(PAYER);
        settlement.fundInvoice(otherId, 500);
    }

    function testDuplicateInvoiceIdIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(InvoiceSettlement.InvoiceExists.selector, INVOICE_ID));
        settlement.registerInvoice(
            INVOICE_ID, PAYER, BENEFICIARY, address(token), 100, uint64(block.timestamp + 30 days), TERMS_HASH
        );
    }

    function testPayerCanCancelAndRefundAfterMandateExpiryWithoutResolver() public {
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));

        vm.warp(uint256(mandateExpiry) + 1);
        vm.prank(PAYER);
        settlement.cancelExpiredInvoice(INVOICE_ID);

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.status == InvoiceSettlement.Status.CANCELLED, "invoice not cancelled");
        require(inv.paid == 2_000, "paid amount changed");
        require(token.balanceOf(PAYER) == 8_000, "unused escrow not refunded");
        require(token.balanceOf(BENEFICIARY) == 2_000, "beneficiary payment changed");
        require(token.balanceOf(address(settlement)) == 0, "escrow should be empty");
    }

    function testCannotCancelBeforeLatestMandateExpiry() public {
        vm.expectRevert(InvoiceSettlement.InvalidDeadline.selector);
        vm.prank(PAYER);
        settlement.cancelExpiredInvoice(INVOICE_ID);
    }

    function testOnlyPayerCanCancelExpiredInvoice() public {
        vm.warp(uint256(mandateExpiry) + 1);
        vm.expectRevert(InvoiceSettlement.Unauthorized.selector);
        vm.prank(STRANGER);
        settlement.cancelExpiredInvoice(INVOICE_ID);
    }

    function testReauthorizationExtendsCancellationWait() public {
        uint64 extendedExpiry = uint64(block.timestamp + 60 days);
        vm.prank(PAYER);
        settlement.authorizeAgent(INVOICE_ID, AGENT, 2_000, 5_000, extendedExpiry);

        vm.warp(uint256(mandateExpiry) + 1);
        vm.expectRevert(InvoiceSettlement.InvalidDeadline.selector);
        vm.prank(PAYER);
        settlement.cancelExpiredInvoice(INVOICE_ID);

        vm.warp(uint256(extendedExpiry) + 1);
        vm.prank(PAYER);
        settlement.cancelExpiredInvoice(INVOICE_ID);

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.status == InvoiceSettlement.Status.CANCELLED, "invoice not cancelled after expiry");
        require(token.balanceOf(PAYER) == 10_000, "unused escrow not fully refunded");
    }

}
