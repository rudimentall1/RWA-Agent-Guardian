// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/InvoiceSettlement.sol";
import "../contracts/DemoAgentExecutor.sol";
import "./TestToken.sol";
import "./TestFeeToken.sol";

interface Vm {
    function prank(address sender) external;
    function warp(uint256 timestamp) external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata revertData) external;
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
}

contract InvoiceSettlementTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant INVOICE_ID = keccak256("INV-2026-001");
    bytes32 private constant TERMS_HASH = keccak256("synthetic-invoice-terms-v1");
    address private constant PAYER = address(0xB0B);
    address private constant BENEFICIARY = address(0xD00D);
    address private constant AGENT = address(0xA11CE);
    address private constant STRANGER = address(0xBAD);
    uint256 private constant ISSUER_PRIVATE_KEY = 0xA77157;

    struct RegistrationAttempt {
        address issuer;
        bytes32 invoiceId;
        uint128 faceValue;
        uint64 dueAt;
        bytes32 documentHash;
        uint256 signingKey;
        uint256 nonce;
    }

    address private issuer;
    uint64 private lastAttestationDeadline;
    bytes private lastAttestationSignature;
    TestToken private token;
    InvoiceSettlement private settlement;
    uint64 private dueAt;
    uint64 private mandateExpiry;

    function setUp() public {
        token = new TestToken();
        settlement = new InvoiceSettlement(address(this));
        issuer = vm.addr(ISSUER_PRIVATE_KEY);
        dueAt = uint64(block.timestamp + 30 days);
        mandateExpiry = uint64(block.timestamp + 1 days);

        token.mint(PAYER, 10_000);
        vm.prank(PAYER);
        token.approve(address(settlement), 10_000);

        _registerInvoice(INVOICE_ID, PAYER, BENEFICIARY, address(token), 10_000, dueAt, TERMS_HASH);
        vm.prank(PAYER);
        settlement.acceptInvoice(INVOICE_ID);
        vm.prank(PAYER);
        settlement.fundInvoice(INVOICE_ID, 10_000);
        vm.prank(PAYER);
        settlement.authorizeAgent(INVOICE_ID, AGENT, 2_000, 5_000, mandateExpiry);
    }

    function testSettlementVersionIdentifiesEscalatedStateMachine() public {
        require(settlement.SETTLEMENT_VERSION() == 2, "settlement version mismatch");
    }

    function _registerInvoice(
        bytes32 invoiceId,
        address payer,
        address beneficiary,
        address invoiceToken,
        uint128 faceValue,
        uint64 invoiceDueAt,
        bytes32 documentHash
    ) internal {
        uint256 nonce = settlement.issuerNonces(issuer);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = settlement.issuerAttestationDigest(
            invoiceId, issuer, payer, beneficiary, invoiceToken, faceValue, invoiceDueAt, documentHash, nonce, deadline
        );
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(ISSUER_PRIVATE_KEY, digest);
        bytes memory signature = abi.encodePacked(r, sigS, v);
        lastAttestationDeadline = deadline;
        lastAttestationSignature = signature;
        vm.prank(issuer);
        settlement.registerInvoice(
            invoiceId,
            payer,
            beneficiary,
            invoiceToken,
            faceValue,
            invoiceDueAt,
            documentHash,
            nonce,
            deadline,
            signature
        );
    }

    function _prepareRegistration(RegistrationAttempt memory attempt)
        internal
        returns (uint64 deadline, bytes memory signature)
    {
        deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = settlement.issuerAttestationDigest(
            attempt.invoiceId,
            attempt.issuer,
            PAYER,
            BENEFICIARY,
            address(token),
            attempt.faceValue,
            attempt.dueAt,
            attempt.documentHash,
            attempt.nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(attempt.signingKey, digest);
        signature = abi.encodePacked(r, sigS, v);
    }

    function _submitRegistration(RegistrationAttempt memory attempt, uint64 deadline, bytes memory signature) internal {
        vm.prank(attempt.issuer);
        settlement.registerInvoice(
            attempt.invoiceId,
            PAYER,
            BENEFICIARY,
            address(token),
            attempt.faceValue,
            attempt.dueAt,
            attempt.documentHash,
            attempt.nonce,
            deadline,
            signature
        );
    }

    function _registerInvoiceUsingKey(RegistrationAttempt memory attempt) internal {
        (uint64 deadline, bytes memory signature) = _prepareRegistration(attempt);
        _submitRegistration(attempt, deadline, signature);
    }

    function testIssuerAttestationIsVerifiedAndRecorded() public view {
        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        bytes32 digest = settlement.issuerAttestationDigest(
            INVOICE_ID,
            issuer,
            PAYER,
            BENEFICIARY,
            address(token),
            10_000,
            dueAt,
            TERMS_HASH,
            0,
            lastAttestationDeadline
        );
        require(settlement.invoiceAttestationDigests(INVOICE_ID) == digest, "attestation digest not recorded");
        require(
            settlement.recoverIssuer(digest, lastAttestationSignature) == issuer, "issuer signature not recoverable"
        );
        require(inv.issuer == issuer, "invoice issuer mismatch");
        require(settlement.issuerNonces(issuer) == 1, "issuer nonce not consumed");
    }

    function testWrongIssuerSignatureIsRejected() public {
        RegistrationAttempt memory attempt = RegistrationAttempt({
            issuer: issuer,
            invoiceId: keccak256("INV-WRONG-ISSUER-SIGNATURE"),
            faceValue: 100,
            dueAt: uint64(block.timestamp + 30 days),
            documentHash: keccak256("wrong-signature-doc"),
            signingKey: 0xBEEF,
            nonce: settlement.issuerNonces(issuer)
        });
        (uint64 deadline, bytes memory signature) = _prepareRegistration(attempt);
        vm.expectRevert(InvoiceSettlement.InvalidAttestation.selector);
        _submitRegistration(attempt, deadline, signature);
    }

    function testStaleIssuerNonceIsRejected() public {
        RegistrationAttempt memory attempt = RegistrationAttempt({
            issuer: issuer,
            invoiceId: keccak256("INV-STALE-ISSUER-NONCE"),
            faceValue: 100,
            dueAt: uint64(block.timestamp + 30 days),
            documentHash: keccak256("stale-nonce-doc"),
            signingKey: ISSUER_PRIVATE_KEY,
            nonce: 0
        });
        (uint64 deadline, bytes memory signature) = _prepareRegistration(attempt);
        vm.expectRevert(InvoiceSettlement.InvalidAttestationNonce.selector);
        _submitRegistration(attempt, deadline, signature);
    }

    function testAnyIssuerCanRegisterWithItsOwnAttestation() public {
        RegistrationAttempt memory attempt = RegistrationAttempt({
            issuer: vm.addr(0x6161),
            invoiceId: keccak256("INV-PERMISSIONLESS-ISSUER"),
            faceValue: 100,
            dueAt: uint64(block.timestamp + 30 days),
            documentHash: keccak256("self-attested-document"),
            signingKey: 0x6161,
            nonce: 0
        });
        _registerInvoiceUsingKey(attempt);
        require(settlement.getInvoice(attempt.invoiceId).issuer == attempt.issuer, "issuer not recorded");
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
        _registerInvoice(
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

    function testCanonicalTermsHashBindsAllInvoiceFieldsAndDocumentHash() public {
        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        bytes32 expected = settlement.computeTermsHash(
            issuer, INVOICE_ID, PAYER, BENEFICIARY, address(token), 10_000, dueAt, TERMS_HASH
        );
        require(inv.termsHash == expected, "stored terms hash is not canonical");
        require(settlement.invoiceDocumentHashes(INVOICE_ID) == TERMS_HASH, "document hash not stored");

        require(
            expected
                != settlement.computeTermsHash(
                    issuer, INVOICE_ID, address(0xB0C), BENEFICIARY, address(token), 10_000, dueAt, TERMS_HASH
                ),
            "payer change did not alter commitment"
        );
        require(
            expected
                != settlement.computeTermsHash(
                    issuer, INVOICE_ID, PAYER, address(0xD00E), address(token), 10_000, dueAt, TERMS_HASH
                ),
            "beneficiary change did not alter commitment"
        );
        require(
            expected
                != settlement.computeTermsHash(
                    issuer, INVOICE_ID, PAYER, BENEFICIARY, address(0x1234), 10_000, dueAt, TERMS_HASH
                ),
            "token change did not alter commitment"
        );
        require(
            expected
                != settlement.computeTermsHash(
                    issuer, INVOICE_ID, PAYER, BENEFICIARY, address(token), 10_001, dueAt, TERMS_HASH
                ),
            "face value change did not alter commitment"
        );
        require(
            expected
                != settlement.computeTermsHash(
                    issuer, INVOICE_ID, PAYER, BENEFICIARY, address(token), 10_000, dueAt + 1, TERMS_HASH
                ),
            "due date change did not alter commitment"
        );
        require(
            expected
                != settlement.computeTermsHash(
                    issuer, INVOICE_ID, PAYER, BENEFICIARY, address(token), 10_000, dueAt, keccak256("other-document")
                ),
            "document hash change did not alter commitment"
        );
    }

    function testDuplicateInvoiceIdIsRejected() public {
        RegistrationAttempt memory attempt = RegistrationAttempt({
            issuer: issuer,
            invoiceId: INVOICE_ID,
            faceValue: 100,
            dueAt: uint64(block.timestamp + 30 days),
            documentHash: TERMS_HASH,
            signingKey: ISSUER_PRIVATE_KEY,
            nonce: settlement.issuerNonces(issuer)
        });
        (uint64 deadline, bytes memory signature) = _prepareRegistration(attempt);
        vm.expectRevert(abi.encodeWithSelector(InvoiceSettlement.InvoiceExists.selector, INVOICE_ID));
        _submitRegistration(attempt, deadline, signature);
    }

    function testPayerCanCancelAndRefundAfterMandateExpiryWithoutResolver() public {
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));

        vm.warp(uint256(dueAt) + 1);
        vm.prank(PAYER);
        settlement.cancelExpiredInvoice(INVOICE_ID);

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.status == InvoiceSettlement.Status.CANCELLED, "invoice not cancelled");
        require(inv.paid == 2_000, "paid amount changed");
        require(token.balanceOf(PAYER) == 8_000, "unused escrow not refunded");
        require(token.balanceOf(BENEFICIARY) == 2_000, "beneficiary payment changed");
        require(token.balanceOf(address(settlement)) == 0, "escrow should be empty");
    }

    function testBeneficiaryCanClaimRemainingEscrowAfterMaturityGrace() public {
        vm.warp(uint256(dueAt) + 30 days + 1);
        vm.prank(BENEFICIARY);
        settlement.claimMaturedInvoice(INVOICE_ID);
        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.paid == inv.funded, "matured claim did not settle funded balance");
        require(inv.status == InvoiceSettlement.Status.CLAIMED, "matured claim status mismatch");
        require(token.balanceOf(BENEFICIARY) == 10_000, "beneficiary did not receive remaining escrow");
    }

    function testDisputeTimeoutEscalatesAndKeepsSettlementFrozen() public {
        vm.prank(PAYER);
        settlement.disputeInvoice(INVOICE_ID);
        vm.warp(block.timestamp + settlement.DISPUTE_TIMEOUT() + 1);
        settlement.expireDispute(INVOICE_ID);
        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.status == InvoiceSettlement.Status.ESCALATED, "timed out dispute was not escalated");

        vm.expectRevert(InvoiceSettlement.WrongStatus.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 0, uint64(block.timestamp + 1 hours));
    }

    function testResolverCanResumeEscalatedDispute() public {
        vm.prank(PAYER);
        settlement.disputeInvoice(INVOICE_ID);
        vm.warp(block.timestamp + settlement.DISPUTE_TIMEOUT() + 1);
        settlement.expireDispute(INVOICE_ID);
        settlement.resolveDispute(INVOICE_ID, true);

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.status == InvoiceSettlement.Status.ACCEPTED, "resolver did not resume invoice");
        require(settlement.disputeStartedAt(INVOICE_ID) == 0, "dispute timestamp was not cleared");

        vm.prank(PAYER);
        settlement.authorizeAgent(
            INVOICE_ID, AGENT, 2_000, 5_000, uint64(block.timestamp + 1 days)
        );

        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 0, uint64(block.timestamp + 1 hours));
        inv = settlement.getInvoice(INVOICE_ID);
        require(inv.paid == 1_000, "settlement did not resume after resolver decision");
    }

    function testResolverCanCancelAndRefundEscalatedDispute() public {
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));
        vm.prank(PAYER);
        settlement.disputeInvoice(INVOICE_ID);

        vm.warp(block.timestamp + settlement.DISPUTE_TIMEOUT() + 1);
        settlement.expireDispute(INVOICE_ID);
        settlement.resolveDispute(INVOICE_ID, false);

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.status == InvoiceSettlement.Status.CANCELLED, "escalated invoice not cancelled");
        require(token.balanceOf(PAYER) == 8_000, "remaining escrow not refunded");
        require(token.balanceOf(address(settlement)) == 0, "escrow should be empty");
    }

    function testOnlyResolverCanResolveEscalatedDispute() public {
        vm.prank(PAYER);
        settlement.disputeInvoice(INVOICE_ID);
        vm.warp(block.timestamp + settlement.DISPUTE_TIMEOUT() + 1);
        settlement.expireDispute(INVOICE_ID);

        vm.expectRevert(InvoiceSettlement.Unauthorized.selector);
        vm.prank(STRANGER);
        settlement.resolveDispute(INVOICE_ID, true);
    }

    function testCannotRefundBeforeInvoiceDueDateEvenAfterMandateExpiry() public {
        vm.warp(uint256(mandateExpiry) + 1);
        vm.expectRevert(InvoiceSettlement.InvalidDeadline.selector);
        vm.prank(PAYER);
        settlement.cancelExpiredInvoice(INVOICE_ID);
    }

    function testMandateExpiryCannotBeExtendedIndefinitely() public {
        uint64 farExpiry = type(uint64).max;
        vm.expectRevert(InvoiceSettlement.InvalidDeadline.selector);
        vm.prank(PAYER);
        settlement.authorizeAgent(INVOICE_ID, address(0xBEEF), 1_000, 2_000, farExpiry);
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
        uint64 extendedExpiry = dueAt + 10 days;
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

    function testFeeOnTransferTokenCannotUnderfundEscrow() public {
        TestFeeToken feeToken = new TestFeeToken();
        bytes32 feeInvoice = keccak256("INV-FEE-FUNDING");
        feeToken.mint(PAYER, 10_000);
        vm.prank(PAYER);
        feeToken.approve(address(settlement), 10_000);
        _registerInvoice(feeInvoice, PAYER, BENEFICIARY, address(feeToken), 10_000, dueAt, TERMS_HASH);
        vm.prank(PAYER);
        settlement.acceptInvoice(feeInvoice);
        feeToken.setFeeBps(1_000);

        vm.expectRevert(InvoiceSettlement.TransferFailed.selector);
        vm.prank(PAYER);
        settlement.fundInvoice(feeInvoice, 10_000);

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(feeInvoice);
        require(inv.funded == 0, "failed funding changed invoice accounting");
        require(feeToken.balanceOf(address(settlement)) == 0, "fee token left unexpected escrow balance");
        require(feeToken.balanceOf(PAYER) == 10_000, "failed transfer did not roll back token state");
    }

    function testFeeOnTransferPayoutRollsBackSettlementAccounting() public {
        TestFeeToken feeToken = new TestFeeToken();
        bytes32 feeInvoice = keccak256("INV-FEE-PAYOUT");
        feeToken.mint(PAYER, 10_000);
        vm.prank(PAYER);
        feeToken.approve(address(settlement), 10_000);
        _registerInvoice(feeInvoice, PAYER, BENEFICIARY, address(feeToken), 10_000, dueAt, TERMS_HASH);
        vm.prank(PAYER);
        settlement.acceptInvoice(feeInvoice);
        vm.prank(PAYER);
        settlement.fundInvoice(feeInvoice, 10_000);
        vm.prank(PAYER);
        settlement.authorizeAgent(feeInvoice, AGENT, 2_000, 5_000, mandateExpiry);
        feeToken.setFeeBps(1_000);

        vm.expectRevert(InvoiceSettlement.TransferFailed.selector);
        vm.prank(AGENT);
        settlement.settle(feeInvoice, 2_000, 0, uint64(block.timestamp + 1 hours));

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(feeInvoice);
        InvoiceSettlement.Mandate memory mandate = settlement.getMandate(feeInvoice, AGENT);
        require(inv.paid == 0, "failed payout changed paid accounting");
        require(mandate.spent == 0 && mandate.nonce == 0, "failed payout changed mandate");
        require(feeToken.balanceOf(address(settlement)) == 10_000, "failed payout changed escrow balance");
        require(feeToken.balanceOf(BENEFICIARY) == 0, "beneficiary received partial fee payout");
    }

    function testResolverAdminCanRotateDisputeResolver() public {
        address nextResolver = address(0x123456);
        settlement.setDisputeResolver(nextResolver);
        require(settlement.disputeResolver() == nextResolver, "resolver was not updated");

        vm.prank(PAYER);
        settlement.disputeInvoice(INVOICE_ID);
        vm.prank(nextResolver);
        settlement.resolveDispute(INVOICE_ID, false);

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        require(inv.status == InvoiceSettlement.Status.CANCELLED, "new resolver could not resolve dispute");
    }

    function testNonAdminCannotRotateDisputeResolver() public {
        vm.expectRevert(InvoiceSettlement.Unauthorized.selector);
        vm.prank(STRANGER);
        settlement.setDisputeResolver(STRANGER);
    }

    function testZeroAddressCannotBecomeDisputeResolver() public {
        vm.expectRevert(InvoiceSettlement.InvalidResolver.selector);
        settlement.setDisputeResolver(address(0));
    }

    function testFuzzAggregateLimitRejectsAdditionalPayment(uint128 fuzzedAmount) public {
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 1, uint64(block.timestamp + 1 hours));

        uint128 amount = 1_001 + uint128(uint256(fuzzedAmount) % 1_000);
        vm.expectRevert(InvoiceSettlement.AgentLimitExceeded.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, amount, 2, uint64(block.timestamp + 1 hours));

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        InvoiceSettlement.Mandate memory mandate = settlement.getMandate(INVOICE_ID, AGENT);
        require(inv.paid == 4_000, "rejected payment changed paid amount");
        require(mandate.spent == 4_000 && mandate.nonce == 2, "rejected payment changed mandate");
        require(token.balanceOf(BENEFICIARY) == 4_000, "rejected payment transferred tokens");
    }

    function testDemoScenarioAllowsTwoThousandBlocksThreeThousandAndStopsAtFiveThousand() public {
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 0, uint64(block.timestamp + 1 hours));

        vm.expectRevert(InvoiceSettlement.AgentLimitExceeded.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 3_000, 1, uint64(block.timestamp + 1 hours));

        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 2_000, 1, uint64(block.timestamp + 1 hours));
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 2, uint64(block.timestamp + 1 hours));

        vm.expectRevert(InvoiceSettlement.AgentLimitExceeded.selector);
        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1, 3, uint64(block.timestamp + 1 hours));

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        InvoiceSettlement.Mandate memory mandate = settlement.getMandate(INVOICE_ID, AGENT);
        require(inv.paid == 5_000, "demo did not stop at aggregate cap");
        require(mandate.spent == 5_000 && mandate.nonce == 3, "blocked calls changed mandate");
        require(token.balanceOf(BENEFICIARY) == 5_000, "beneficiary received unexpected amount");
        require(token.balanceOf(address(settlement)) == 5_000, "remaining escrow mismatch");
    }


    function testTokenCallbackCannotReenterSettlement() public {
        vm.prank(PAYER);
        settlement.authorizeAgent(INVOICE_ID, address(token), 1_000, 2_000, mandateExpiry);

        token.configureCallback(
            address(settlement),
            abi.encodeWithSelector(
                settlement.settle.selector,
                INVOICE_ID,
                uint128(1_000),
                uint64(1),
                uint64(block.timestamp + 1 hours)
            )
        );

        vm.prank(AGENT);
        settlement.settle(INVOICE_ID, 1_000, 0, uint64(block.timestamp + 1 hours));

        require(token.callbackAttempted(), "token callback was not attempted");
        require(token.callbackBlocked(), "reentrant settlement was not blocked");

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        InvoiceSettlement.Mandate memory originalMandate = settlement.getMandate(INVOICE_ID, AGENT);
        InvoiceSettlement.Mandate memory tokenMandate = settlement.getMandate(INVOICE_ID, address(token));
        require(inv.paid == 1_000, "callback changed paid amount");
        require(originalMandate.spent == 1_000 && originalMandate.nonce == 1, "outer mandate state mismatch");
        require(tokenMandate.spent == 0 && tokenMandate.nonce == 0, "reentrant call changed token mandate");
        require(token.balanceOf(BENEFICIARY) == 1_000, "callback caused an extra transfer");
    }

    function testCanonicalTermsHashBindsIssuerAndInvoiceId() public {
        bytes32 expected = settlement.computeTermsHash(
            address(this), INVOICE_ID, PAYER, BENEFICIARY, address(token), 10_000, dueAt, TERMS_HASH
        );

        require(
            expected
                != settlement.computeTermsHash(
                    address(0xCAFE), INVOICE_ID, PAYER, BENEFICIARY, address(token), 10_000, dueAt, TERMS_HASH
                ),
            "issuer change did not alter commitment"
        );
        require(
            expected
                != settlement.computeTermsHash(
                    address(this),
                    keccak256("INV-2026-002"),
                    PAYER,
                    BENEFICIARY,
                    address(token),
                    10_000,
                    dueAt,
                    TERMS_HASH
                ),
            "invoice ID change did not alter commitment"
        );
    }
    uint256 private constant INTENT_PRIVATE_KEY = 0xA77158;

    function _deployAuthorizedIntentExecutor(uint256 signingKey) internal returns (DemoAgentExecutor executor) {
        executor = new DemoAgentExecutor(address(settlement), vm.addr(signingKey));
        vm.prank(PAYER);
        settlement.authorizeAgent(INVOICE_ID, address(executor), 2_000, 5_000, mandateExpiry);
    }

    function _signAgentIntent(
        DemoAgentExecutor executor,
        uint256 signingKey,
        uint128 amount,
        uint64 nonce,
        uint64 deadline,
        bytes32 contextHash,
        bytes32 decisionHash
    ) internal returns (bytes memory signature) {
        bytes32 digest = executor.intentDigest(
            INVOICE_ID, amount, nonce, deadline, contextHash, decisionHash
        );
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(signingKey, digest);
        signature = abi.encodePacked(r, sigS, v);
    }

    function testOwnerSignedIntentExecutesThroughOnchainPolicyGate() public {
        DemoAgentExecutor executor = _deployAuthorizedIntentExecutor(INTENT_PRIVATE_KEY);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 contextHash = keccak256("verified payment context");
        bytes32 decisionHash = keccak256("model ALLOW amount 1000 reason invoice accepted");
        bytes memory signature = _signAgentIntent(
            executor, INTENT_PRIVATE_KEY, 1_000, 0, deadline, contextHash, decisionHash
        );

        require(
            executor.verifyIntent(
                INVOICE_ID, 1_000, 0, deadline, contextHash, decisionHash, signature
            ),
            "valid owner intent did not verify"
        );

        vm.prank(STRANGER);
        executor.executeWithIntent(
            INVOICE_ID, 1_000, 0, deadline, contextHash, decisionHash, signature
        );

        InvoiceSettlement.Invoice memory inv = settlement.getInvoice(INVOICE_ID);
        InvoiceSettlement.Mandate memory mandate = settlement.getMandate(INVOICE_ID, address(executor));
        require(inv.paid == 1_000, "signed intent was not settled");
        require(mandate.spent == 1_000 && mandate.nonce == 1, "onchain mandate state mismatch");
        require(token.balanceOf(BENEFICIARY) == 1_000, "beneficiary transfer mismatch");
    }

    function testSignedIntentRejectsAnotherSigner() public {
        DemoAgentExecutor executor = _deployAuthorizedIntentExecutor(INTENT_PRIVATE_KEY);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 contextHash = keccak256("context");
        bytes32 decisionHash = keccak256("decision");
        bytes memory badSignature = _signAgentIntent(
            executor, INTENT_PRIVATE_KEY + 1, 1_000, 0, deadline, contextHash, decisionHash
        );

        require(
            !executor.verifyIntent(
                INVOICE_ID, 1_000, 0, deadline, contextHash, decisionHash, badSignature
            ),
            "signature from a different signer verified"
        );
        vm.expectRevert(DemoAgentExecutor.InvalidIntentSignature.selector);
        vm.prank(STRANGER);
        executor.executeWithIntent(
            INVOICE_ID, 1_000, 0, deadline, contextHash, decisionHash, badSignature
        );
    }

    function testSignedIntentCannotBeReplayedAfterNonceAdvances() public {
        DemoAgentExecutor executor = _deployAuthorizedIntentExecutor(INTENT_PRIVATE_KEY);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 contextHash = keccak256("context");
        bytes32 decisionHash = keccak256("decision");
        bytes memory signature = _signAgentIntent(
            executor, INTENT_PRIVATE_KEY, 1_000, 0, deadline, contextHash, decisionHash
        );

        executor.executeWithIntent(
            INVOICE_ID, 1_000, 0, deadline, contextHash, decisionHash, signature
        );
        vm.expectRevert(InvoiceSettlement.InvalidNonce.selector);
        executor.executeWithIntent(
            INVOICE_ID, 1_000, 0, deadline, contextHash, decisionHash, signature
        );
        require(token.balanceOf(BENEFICIARY) == 1_000, "replay transferred extra tokens");
    }

    function testSignedIntentIsBoundToExecutorDomainAndDecisionHashes() public {
        DemoAgentExecutor executor = _deployAuthorizedIntentExecutor(INTENT_PRIVATE_KEY);
        DemoAgentExecutor otherExecutor = new DemoAgentExecutor(address(settlement), vm.addr(INTENT_PRIVATE_KEY));
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 contextHash = keccak256("context one");
        bytes32 decisionHash = keccak256("decision one");
        bytes32 digest = executor.intentDigest(
            INVOICE_ID, 1_000, 0, deadline, contextHash, decisionHash
        );

        require(
            digest != otherExecutor.intentDigest(
                INVOICE_ID, 1_000, 0, deadline, contextHash, decisionHash
            ),
            "signature domain not bound to executor"
        );
        require(
            digest != executor.intentDigest(
                INVOICE_ID, 1_000, 0, deadline, contextHash, keccak256("different decision")
            ),
            "decision hash not bound to intent"
        );
        require(
            digest != executor.intentDigest(
                INVOICE_ID, 1_000, 0, deadline, keccak256("different context"), decisionHash
            ),
            "context hash not bound to intent"
        );
    }

}
