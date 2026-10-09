// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/DemoSettlementToken.sol";

interface VmToken {
    function prank(address sender) external;
    function expectRevert(bytes4 selector) external;
}

contract DemoSettlementTokenTest {
    VmToken private constant vm = VmToken(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant STRANGER = address(0xBAD);
    address private constant RECIPIENT = address(0xBEEF);

    DemoSettlementToken private token;

    function setUp() public {
        token = new DemoSettlementToken(address(this));
    }

    function testOnlyOwnerCanMint() public {
        vm.expectRevert(DemoSettlementToken.Unauthorized.selector);
        vm.prank(STRANGER);
        token.mint(RECIPIENT, 1_000);
    }

    function testAllowanceIsConsumedOnTransferFrom() public {
        token.mint(address(this), 1_000);
        token.approve(STRANGER, 300);

        vm.prank(STRANGER);
        bool moved = token.transferFrom(address(this), RECIPIENT, 200);
        require(moved, "transferFrom failed");

        require(token.balanceOf(RECIPIENT) == 200, "recipient balance mismatch");
        require(token.allowance(address(this), STRANGER) == 100, "allowance not reduced");
    }

    function testCannotTransferMoreThanBalance() public {
        token.mint(address(this), 10);
        (bool success,) =
            address(token).call(abi.encodeWithSelector(DemoSettlementToken.transfer.selector, RECIPIENT, 11));
        require(!success, "transfer should have reverted");
    }
}
