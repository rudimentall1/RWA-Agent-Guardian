// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/InvoiceSettlement.sol";
import "../contracts/DemoSettlementToken.sol";
import "../contracts/DemoAgentExecutor.sol";

interface VmDeploy {
    function envUint(string calldata name) external returns (uint256);
    function envAddress(string calldata name) external returns (address);
    function addr(uint256 privateKey) external returns (address);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract Deploy {
    VmDeploy private constant vm = VmDeploy(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (address tokenAddress, address settlementAddress, address executorAddress) {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address payer = vm.envAddress("PAYER_ADDRESS");
        address beneficiary = vm.envAddress("BENEFICIARY_ADDRESS");

        uint128 faceValue = 10_000 * 10 ** 6;
        bytes32 invoiceId = keccak256("INV-1001");
        bytes32 termsHash = keccak256("INV-1001|Synthetic invoice|10000 dUSD|NET30|v1");
        uint64 dueAt = uint64(block.timestamp + 30 days);

        vm.startBroadcast(privateKey);
        DemoSettlementToken token = new DemoSettlementToken(deployer);
        InvoiceSettlement settlement = new InvoiceSettlement(deployer);
        DemoAgentExecutor executor = new DemoAgentExecutor(address(settlement), payer);

        settlement.registerInvoice(invoiceId, payer, beneficiary, address(token), faceValue, dueAt, termsHash);
        token.mint(payer, faceValue);
        vm.stopBroadcast();

        return (address(token), address(settlement), address(executor));
    }
}
