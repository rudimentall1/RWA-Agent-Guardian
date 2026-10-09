// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Settlement {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Escrow settlement for a synthetic receivable, controlled by an explicit invoice lifecycle.
contract InvoiceSettlement {
    enum Status {
        NONE,
        REGISTERED,
        ACCEPTED,
        DISPUTED,
        SETTLED,
        CANCELLED,
        CLAIMED
    }

    struct Invoice {
        address issuer;
        address payer;
        address beneficiary;
        address token;
        uint128 faceValue;
        uint128 funded;
        uint128 paid;
        uint64 dueAt;
        bytes32 termsHash;
        Status status;
    }

    struct Mandate {
        uint128 perPaymentLimit;
        uint128 totalLimit;
        uint128 spent;
        uint64 expiresAt;
        uint64 nonce;
        bool active;
    }

    address public disputeResolver;
    address public immutable disputeResolverAdmin;
    bytes32 public constant INVOICE_TERMS_DOMAIN = keccak256("RWA_AGENT_GUARDIAN_INVOICE_V1");
    uint64 public constant MAX_MANDATE_EXTENSION = 30 days;
    uint64 public constant DISPUTE_TIMEOUT = 7 days;
    mapping(address => bool) public approvedIssuers;
    mapping(bytes32 => Invoice) public invoices;
    mapping(bytes32 => bytes32) public invoiceDocumentHashes;
    mapping(bytes32 => mapping(address => Mandate)) public mandates;
    mapping(bytes32 => uint64) public latestMandateExpiry;
    mapping(bytes32 => uint64) public disputeStartedAt;
    bool private entered;

    error Unauthorized();
    error InvalidInvoice();
    error InvoiceExists(bytes32 invoiceId);
    error WrongStatus();
    error InvalidTerms();
    error InvalidAmount();
    error InvalidAgent();
    error InvalidDeadline();
    error InvalidNonce();
    error AgentLimitExceeded();
    error InsufficientEscrow();
    error TransferFailed();
    error Reentrancy();
    error InvalidResolver();

    event IssuerApprovalUpdated(address indexed issuer, bool approved);
    event InvoiceRegistered(
        bytes32 indexed invoiceId,
        address indexed issuer,
        address indexed payer,
        address beneficiary,
        address token,
        uint256 faceValue,
        uint64 dueAt,
        bytes32 termsHash
    );
    event InvoiceAccepted(bytes32 indexed invoiceId, address indexed payer);
    event InvoiceFunded(bytes32 indexed invoiceId, uint256 amount, uint256 totalFunded);
    event AgentAuthorized(
        bytes32 indexed invoiceId, address indexed agent, uint256 perPaymentLimit, uint256 totalLimit, uint64 expiresAt
    );
    event AgentRevoked(bytes32 indexed invoiceId, address indexed agent);
    event InvoiceDisputed(bytes32 indexed invoiceId, address indexed payer);
    event DisputeTimedOut(bytes32 indexed invoiceId);
    event BeneficiaryClaimed(bytes32 indexed invoiceId, address indexed beneficiary, uint256 amount);
    event DisputeResolved(bytes32 indexed invoiceId, bool resumed);
    event DisputeResolverUpdated(address indexed previousResolver, address indexed newResolver);
    event InvoiceRefunded(bytes32 indexed invoiceId, address indexed payer, uint256 amount);
    event InvoiceCancelled(bytes32 indexed invoiceId, address indexed payer, uint256 refunded);
    event SettlementExecuted(
        bytes32 indexed invoiceId,
        address indexed agent,
        address indexed beneficiary,
        uint256 amount,
        uint256 totalPaid,
        uint64 nonce
    );

    constructor(address resolver) {
        if (resolver == address(0)) revert InvalidResolver();
        disputeResolver = resolver;
        disputeResolverAdmin = msg.sender;
    }

    /// @notice Rotate the trusted dispute resolver if its key is lost or must be replaced.
    /// @dev The deployer remains a privileged admin; production deployments should use a multisig.
    function setDisputeResolver(address newResolver) external nonReentrant {
        if (msg.sender != disputeResolverAdmin) revert Unauthorized();
        if (newResolver == address(0)) revert InvalidResolver();
        address previousResolver = disputeResolver;
        disputeResolver = newResolver;
        emit DisputeResolverUpdated(previousResolver, newResolver);
    }

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    /// @notice Admin-managed issuer allowlist for this prototype. This is not proof of a legal receivable.
    function setIssuerApproval(address issuer, bool approved) external nonReentrant {
        if (msg.sender != disputeResolverAdmin) revert Unauthorized();
        if (issuer == address(0)) revert InvalidTerms();
        approvedIssuers[issuer] = approved;
        emit IssuerApprovalUpdated(issuer, approved);
    }

    /// @notice Computes the canonical invoice commitment for a given on-chain record and document hash.
    function computeTermsHash(
        address issuer,
        bytes32 invoiceId,
        address payer,
        address beneficiary,
        address token,
        uint128 faceValue,
        uint64 dueAt,
        bytes32 documentHash
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                INVOICE_TERMS_DOMAIN, issuer, invoiceId, payer, beneficiary, token, faceValue, dueAt, documentHash
            )
        );
    }

    function registerInvoice(
        bytes32 invoiceId,
        address payer,
        address beneficiary,
        address token,
        uint128 faceValue,
        uint64 dueAt,
        bytes32 documentHash
    ) external nonReentrant {
        if (invoiceId == bytes32(0) || invoices[invoiceId].status != Status.NONE) {
            revert InvoiceExists(invoiceId);
        }
        if (!approvedIssuers[msg.sender]) revert Unauthorized();
        if (
            payer == address(0) || beneficiary == address(0) || token == address(0) || payer == msg.sender
                || payer == beneficiary || faceValue == 0 || dueAt <= block.timestamp
        ) revert InvalidTerms();
        if (documentHash == bytes32(0)) revert InvalidTerms();

        bytes32 termsHash =
            computeTermsHash(msg.sender, invoiceId, payer, beneficiary, token, faceValue, dueAt, documentHash);
        invoiceDocumentHashes[invoiceId] = documentHash;
        invoices[invoiceId] = Invoice({
            issuer: msg.sender,
            payer: payer,
            beneficiary: beneficiary,
            token: token,
            faceValue: faceValue,
            funded: 0,
            paid: 0,
            dueAt: dueAt,
            termsHash: termsHash,
            status: Status.REGISTERED
        });

        emit InvoiceRegistered(invoiceId, msg.sender, payer, beneficiary, token, faceValue, dueAt, termsHash);
    }

    function acceptInvoice(bytes32 invoiceId) external nonReentrant {
        Invoice storage inv = _invoice(invoiceId);
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != Status.REGISTERED) revert WrongStatus();
        if (block.timestamp >= inv.dueAt) revert InvalidDeadline();

        inv.status = Status.ACCEPTED;
        emit InvoiceAccepted(invoiceId, msg.sender);
    }

    function fundInvoice(bytes32 invoiceId, uint128 amount) external nonReentrant {
        Invoice storage inv = _invoice(invoiceId);
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != Status.ACCEPTED) revert WrongStatus();
        if (amount == 0 || uint256(inv.funded) + amount > inv.faceValue) revert InvalidAmount();

        _transferFromExact(inv.token, msg.sender, address(this), amount);
        inv.funded += amount;
        emit InvoiceFunded(invoiceId, amount, inv.funded);
    }

    function authorizeAgent(
        bytes32 invoiceId,
        address agent,
        uint128 perPaymentLimit,
        uint128 totalLimit,
        uint64 expiresAt
    ) external nonReentrant {
        Invoice storage inv = _invoice(invoiceId);
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != Status.ACCEPTED) revert WrongStatus();
        if (
            agent == address(0) || agent == inv.payer || perPaymentLimit == 0 || totalLimit < perPaymentLimit
                || totalLimit > inv.faceValue
        ) revert InvalidAgent();
        if (expiresAt <= block.timestamp || uint256(expiresAt) > uint256(inv.dueAt) + MAX_MANDATE_EXTENSION) {
            revert InvalidDeadline();
        }

        Mandate storage m = mandates[invoiceId][agent];
        if (totalLimit < m.spent) revert AgentLimitExceeded();
        m.perPaymentLimit = perPaymentLimit;
        m.totalLimit = totalLimit;
        m.expiresAt = expiresAt;
        m.active = true;
        if (expiresAt > latestMandateExpiry[invoiceId]) latestMandateExpiry[invoiceId] = expiresAt;

        emit AgentAuthorized(invoiceId, agent, perPaymentLimit, totalLimit, expiresAt);
    }

    function revokeAgent(bytes32 invoiceId, address agent) external nonReentrant {
        Invoice storage inv = _invoice(invoiceId);
        if (msg.sender != inv.payer) revert Unauthorized();

        Mandate storage m = mandates[invoiceId][agent];
        if (!m.active) revert InvalidAgent();
        m.active = false;
        emit AgentRevoked(invoiceId, agent);
    }

    function disputeInvoice(bytes32 invoiceId) external nonReentrant {
        Invoice storage inv = _invoice(invoiceId);
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != Status.ACCEPTED) revert WrongStatus();

        inv.status = Status.DISPUTED;
        disputeStartedAt[invoiceId] = uint64(block.timestamp);
        emit InvoiceDisputed(invoiceId, msg.sender);
    }

    /// @notice Lets the payer recover unused escrow after every authorized mandate must have expired.
    /// @dev The latest expiry is monotonic, so reauthorizing an agent extends the cancellation wait.
    function cancelExpiredInvoice(bytes32 invoiceId) external nonReentrant {
        Invoice storage inv = _invoice(invoiceId);
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != Status.ACCEPTED) revert WrongStatus();

        if (block.timestamp < inv.dueAt) revert InvalidDeadline();

        uint64 latestExpiry = latestMandateExpiry[invoiceId];
        if (latestExpiry == 0) {
            if (block.timestamp < inv.dueAt) revert InvalidDeadline();
        } else if (block.timestamp <= latestExpiry) {
            revert InvalidDeadline();
        }
        if (block.timestamp > uint256(inv.dueAt) + MAX_MANDATE_EXTENSION) revert InvalidDeadline();

        inv.status = Status.CANCELLED;
        uint256 refund = uint256(inv.funded) - inv.paid;
        if (refund > 0) _transferExact(inv.token, inv.payer, refund);
        if (refund > 0) emit InvoiceRefunded(invoiceId, inv.payer, refund);
        emit InvoiceCancelled(invoiceId, inv.payer, refund);
    }

    function resolveDispute(bytes32 invoiceId, bool resume) external nonReentrant {
        if (msg.sender != disputeResolver) revert Unauthorized();
        Invoice storage inv = _invoice(invoiceId);
        if (inv.status != Status.DISPUTED) revert WrongStatus();
        uint64 startedAt = disputeStartedAt[invoiceId];
        if (startedAt == 0 || block.timestamp > uint256(startedAt) + DISPUTE_TIMEOUT) revert InvalidDeadline();
        delete disputeStartedAt[invoiceId];

        if (resume) {
            inv.status = Status.ACCEPTED;
        } else {
            inv.status = Status.CANCELLED;
            uint256 refund = uint256(inv.funded) - inv.paid;
            if (refund > 0) _transferExact(inv.token, inv.payer, refund);
            if (refund > 0) emit InvoiceRefunded(invoiceId, inv.payer, refund);
        }
        emit DisputeResolved(invoiceId, resume);
    }

    /// @notice Reopens an unresolved dispute after a fixed timeout so funds cannot remain frozen forever.
    /// @dev Timeout resumes the invoice; it does not decide the underlying commercial dispute.
    function expireDispute(bytes32 invoiceId) external nonReentrant {
        Invoice storage inv = _invoice(invoiceId);
        if (inv.status != Status.DISPUTED) revert WrongStatus();
        uint64 startedAt = disputeStartedAt[invoiceId];
        if (startedAt == 0 || block.timestamp <= uint256(startedAt) + DISPUTE_TIMEOUT) revert InvalidDeadline();
        delete disputeStartedAt[invoiceId];
        inv.status = Status.ACCEPTED;
        emit DisputeTimedOut(invoiceId);
    }

    /// @notice Allows the named beneficiary to claim remaining funded escrow after maturity and the mandate grace period.
    function claimMaturedInvoice(bytes32 invoiceId) external nonReentrant {
        Invoice storage inv = _invoice(invoiceId);
        if (msg.sender != inv.beneficiary) revert Unauthorized();
        if (inv.status != Status.ACCEPTED) revert WrongStatus();
        if (block.timestamp <= uint256(inv.dueAt) + MAX_MANDATE_EXTENSION) revert InvalidDeadline();
        uint64 latestExpiry = latestMandateExpiry[invoiceId];
        if (latestExpiry != 0 && block.timestamp <= latestExpiry) revert InvalidDeadline();
        uint256 amount = uint256(inv.funded) - inv.paid;
        if (amount == 0) revert InvalidAmount();
        inv.paid = inv.funded;
        inv.status = Status.CLAIMED;
        _transferExact(inv.token, inv.beneficiary, amount);
        emit BeneficiaryClaimed(invoiceId, inv.beneficiary, amount);
    }

    function settle(bytes32 invoiceId, uint128 amount, uint64 nonce, uint64 deadline) external nonReentrant {
        Invoice storage inv = _invoice(invoiceId);
        if (inv.status != Status.ACCEPTED) revert WrongStatus();

        Mandate storage m = mandates[invoiceId][msg.sender];
        if (!m.active || block.timestamp > m.expiresAt) revert InvalidAgent();
        if (block.timestamp > deadline || deadline > m.expiresAt) revert InvalidDeadline();
        if (amount == 0 || uint256(inv.paid) + amount > inv.faceValue) revert InvalidAmount();
        if (nonce != m.nonce) revert InvalidNonce();
        if (amount > m.perPaymentLimit || uint256(m.spent) + amount > m.totalLimit) {
            revert AgentLimitExceeded();
        }
        if (uint256(inv.paid) + amount > inv.funded) revert InsufficientEscrow();

        // Effects precede the external token call; any failure reverts the whole transition.
        uint64 usedNonce = m.nonce;
        m.spent += amount;
        m.nonce += 1;
        inv.paid += amount;
        if (inv.paid == inv.faceValue) inv.status = Status.SETTLED;

        _transferExact(inv.token, inv.beneficiary, amount);
        emit SettlementExecuted(invoiceId, msg.sender, inv.beneficiary, amount, inv.paid, usedNonce);
    }

    function getInvoice(bytes32 invoiceId) external view returns (Invoice memory) {
        return _invoiceView(invoiceId);
    }

    function getMandate(bytes32 invoiceId, address agent) external view returns (Mandate memory) {
        return mandates[invoiceId][agent];
    }

    function _transferFromExact(address token, address from, address to, uint256 amount) private {
        IERC20Settlement asset = IERC20Settlement(token);
        uint256 senderBefore = asset.balanceOf(from);
        uint256 recipientBefore = asset.balanceOf(to);
        if (!asset.transferFrom(from, to, amount)) revert TransferFailed();
        uint256 senderAfter = asset.balanceOf(from);
        uint256 recipientAfter = asset.balanceOf(to);
        if (
            senderAfter > senderBefore || senderBefore - senderAfter != amount || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != amount
        ) revert TransferFailed();
    }

    function _transferExact(address token, address to, uint256 amount) private {
        IERC20Settlement asset = IERC20Settlement(token);
        uint256 senderBefore = asset.balanceOf(address(this));
        uint256 recipientBefore = asset.balanceOf(to);
        if (!asset.transfer(to, amount)) revert TransferFailed();
        uint256 senderAfter = asset.balanceOf(address(this));
        uint256 recipientAfter = asset.balanceOf(to);
        if (
            senderAfter > senderBefore || senderBefore - senderAfter != amount || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != amount
        ) revert TransferFailed();
    }

    function _invoice(bytes32 invoiceId) private view returns (Invoice storage inv) {
        inv = invoices[invoiceId];
        if (inv.status == Status.NONE) revert InvalidInvoice();
    }

    function _invoiceView(bytes32 invoiceId) private view returns (Invoice memory inv) {
        inv = invoices[invoiceId];
        if (inv.status == Status.NONE) revert InvalidInvoice();
    }
}
