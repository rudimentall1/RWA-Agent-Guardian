// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/InvoiceSettlement.sol";
import "../contracts/DemoSettlementToken.sol";
import "../contracts/DemoAgentExecutor.sol";

interface VmDeploy {
    function envUint(string calldata name) external returns (uint256);
    function envAddress(string calldata name) external returns (address);
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract Deploy {
    struct InitialInvoice {
        bytes32 invoiceId;
        address payer;
        address beneficiary;
        address token;
        uint128 faceValue;
        uint64 dueAt;
        bytes32 documentHash;
    }

    struct SignedInitialInvoice {
        bytes32 invoiceId;
        address payer;
        address beneficiary;
        address token;
        uint128 faceValue;
        uint64 dueAt;
        bytes32 documentHash;
        uint256 nonce;
        uint64 deadline;
        bytes signature;
    }

    VmDeploy private constant vm = VmDeploy(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (address tokenAddress, address settlementAddress, address executorAddress) {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address payer = vm.envAddress("PAYER_ADDRESS");
        address beneficiary = vm.envAddress("BENEFICIARY_ADDRESS");
        address agentOwner = vm.envAddress("AGENT_OWNER_ADDRESS");
        require(agentOwner != payer, "agent owner must differ from payer");

        uint128 faceValue = 10_000 * 10 ** 6;
        bytes32 invoiceId = keccak256("INV-1001");
        bytes32 documentHash = keccak256("INV-1001|Synthetic invoice|10000 dUSD|NET30|v1");
        uint64 dueAt = uint64(block.timestamp + 30 days);

        vm.startBroadcast(privateKey);
        DemoSettlementToken token = new DemoSettlementToken(deployer);
        InvoiceSettlement settlement = new InvoiceSettlement(deployer);
        DemoAgentExecutor executor = new DemoAgentExecutor(address(settlement), agentOwner);
        _registerInitialInvoice(
            settlement,
            privateKey,
            InitialInvoice(invoiceId, payer, beneficiary, address(token), faceValue, dueAt, documentHash)
        );
        token.mint(payer, faceValue);
        vm.stopBroadcast();

        return (address(token), address(settlement), address(executor));
    }

    function _initialDigest(
        InvoiceSettlement settlement,
        address issuer,
        uint256 nonce,
        uint64 deadline,
        InitialInvoice memory invoice
    ) private view returns (bytes32) {
        bytes32 typeHash = keccak256(
            "InvoiceAttestation(bytes32 invoiceId,address issuer,address payer,address beneficiary,address token,uint128 faceValue,uint64 dueAt,bytes32 documentHash,uint256 nonce,uint64 deadline)"
        );
        bytes memory firstWords =
            abi.encode(typeHash, invoice.invoiceId, issuer, invoice.payer, invoice.beneficiary, invoice.token);
        bytes memory lastWords = abi.encode(invoice.faceValue, invoice.dueAt, invoice.documentHash, nonce, deadline);
        bytes32 structHash = keccak256(bytes.concat(firstWords, lastWords));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("RWA Agent Guardian"),
                keccak256("1"),
                block.chainid,
                address(settlement)
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _registerInitialInvoice(InvoiceSettlement settlement, uint256 issuerKey, InitialInvoice memory invoice)
        private
    {
        address issuer = vm.addr(issuerKey);
        SignedInitialInvoice memory signedInvoice;
        signedInvoice.invoiceId = invoice.invoiceId;
        signedInvoice.payer = invoice.payer;
        signedInvoice.beneficiary = invoice.beneficiary;
        signedInvoice.token = invoice.token;
        signedInvoice.faceValue = invoice.faceValue;
        signedInvoice.dueAt = invoice.dueAt;
        signedInvoice.documentHash = invoice.documentHash;
        signedInvoice.nonce = settlement.issuerNonces(issuer);
        signedInvoice.deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = _initialDigest(settlement, issuer, signedInvoice.nonce, signedInvoice.deadline, invoice);
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(issuerKey, digest);
        signedInvoice.signature = abi.encodePacked(r, sigS, v);
        _submitInitialInvoice(settlement, signedInvoice);
    }

    function _submitInitialInvoice(InvoiceSettlement settlement, SignedInitialInvoice memory invoice) private {
        settlement.registerInvoice(
            invoice.invoiceId,
            invoice.payer,
            invoice.beneficiary,
            invoice.token,
            invoice.faceValue,
            invoice.dueAt,
            invoice.documentHash,
            invoice.nonce,
            invoice.deadline,
            invoice.signature
        );
    }
}
