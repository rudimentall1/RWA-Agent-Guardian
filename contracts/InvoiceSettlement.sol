// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Settlement {
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
        CANCELLED
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

    address public immutable disputeResolver;
    mapping(bytes32 => Invoice) public invoices;
    mapping(bytes32 => mapping(address => Mandate)) public mandates;
    mapping(bytes32 => uint64) public latestMandateExpiry;
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
    event DisputeResolved(bytes32 indexed invoiceId, bool resumed);
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
        if (resolver == address(0)) revert Unauthorized();
        disputeResolver = resolver;
    }

    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    function registerInvoice(
        bytes32 invoiceId,
        address payer,
        address beneficiary,
        address token,
        uint128 faceValue,
        uint64 dueAt,
        bytes32 termsHash
    ) external nonReentrant {
        if (invoiceId == bytes32(0) || invoices[invoiceId].status != Status.NONE) {
            revert InvoiceExists(invoiceId);
        }
        if (
            payer == address(0) || beneficiary == address(0) || token == address(0) || payer == msg.sender
                || payer == beneficiary || faceValue == 0 || dueAt <= block.timestamp
        ) revert InvalidTerms();
        if (termsHash == bytes32(0)) revert InvalidTerms();

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

        inv.funded += amount;
        if (!IERC20Settlement(inv.token).transferFrom(msg.sender, address(this), amount)) {
            revert TransferFailed();
        }
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
        if (expiresAt <= block.timestamp) revert InvalidDeadline();

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
        emit InvoiceDisputed(invoiceId, msg.sender);
    }

    /// @notice Lets the payer recover unused escrow after every authorized mandate must have expired.
    /// @dev The latest expiry is monotonic, so reauthorizing an agent extends the cancellation wait.
    function cancelExpiredInvoice(bytes32 invoiceId) external nonReentrant {
        Invoice storage inv = _invoice(invoiceId);
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != Status.ACCEPTED) revert WrongStatus();

        uint64 latestExpiry = latestMandateExpiry[invoiceId];
        if (latestExpiry == 0) {
            if (block.timestamp < inv.dueAt) revert InvalidDeadline();
        } else if (block.timestamp <= latestExpiry) {
            revert InvalidDeadline();
        }

        inv.status = Status.CANCELLED;
        uint256 refund = uint256(inv.funded) - inv.paid;
        if (refund > 0 && !IERC20Settlement(inv.token).transfer(inv.payer, refund)) {
            revert TransferFailed();
        }
        if (refund > 0) emit InvoiceRefunded(invoiceId, inv.payer, refund);
        emit InvoiceCancelled(invoiceId, inv.payer, refund);
    }

    function resolveDispute(bytes32 invoiceId, bool resume) external nonReentrant {
        if (msg.sender != disputeResolver) revert Unauthorized();
        Invoice storage inv = _invoice(invoiceId);
        if (inv.status != Status.DISPUTED) revert WrongStatus();

        if (resume) {
            inv.status = Status.ACCEPTED;
        } else {
            inv.status = Status.CANCELLED;
            uint256 refund = uint256(inv.funded) - inv.paid;
            if (refund > 0 && !IERC20Settlement(inv.token).transfer(inv.payer, refund)) {
                revert TransferFailed();
            }
            if (refund > 0) emit InvoiceRefunded(invoiceId, inv.payer, refund);
        }
        emit DisputeResolved(invoiceId, resume);
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

        if (!IERC20Settlement(inv.token).transfer(inv.beneficiary, amount)) {
            revert TransferFailed();
        }
        emit SettlementExecuted(invoiceId, msg.sender, inv.beneficiary, amount, inv.paid, usedNonce);
    }

    function getInvoice(bytes32 invoiceId) external view returns (Invoice memory) {
        return _invoiceView(invoiceId);
    }

    function getMandate(bytes32 invoiceId, address agent) external view returns (Mandate memory) {
        return mandates[invoiceId][agent];
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
