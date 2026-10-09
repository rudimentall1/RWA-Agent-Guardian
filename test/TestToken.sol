// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract TestToken {
    string public constant name = "Demo Settlement Dollar";
    string public constant symbol = "dUSD";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public failTransfers;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackBlocked;

    error InsufficientBalance();
    error InsufficientAllowance();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setFailTransfers(bool value) external {
        failTransfers = value;
    }

    function configureCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackAttempted = false;
        callbackBlocked = false;
    }

    function _attemptCallback() private {
        if (callbackTarget == address(0) || callbackAttempted) return;
        callbackAttempted = true;
        (bool ok,) = callbackTarget.call(callbackData);
        callbackBlocked = !ok;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (failTransfers) return false;
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        _attemptCallback();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (failTransfers) return false;
        if (balanceOf[from] < amount) revert InsufficientBalance();
        uint256 permitted = allowance[from][msg.sender];
        if (permitted < amount) revert InsufficientAllowance();
        allowance[from][msg.sender] = permitted - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
