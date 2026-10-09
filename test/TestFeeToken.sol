// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Test fixture for ERC-20 tokens that charge a transfer fee.
contract TestFeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint16 public feeBps;

    error InsufficientBalance();
    error InsufficientAllowance();
    error InvalidFee();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setFeeBps(uint16 value) external {
        if (value > 10_000) revert InvalidFee();
        feeBps = value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        if (permitted < amount) revert InsufficientAllowance();
        allowance[from][msg.sender] = permitted - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount - (amount * feeBps / 10_000);
    }
}
