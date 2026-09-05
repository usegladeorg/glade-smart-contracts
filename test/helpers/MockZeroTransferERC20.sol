// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Simulates a fee-on-transfer token whose fee consumes the whole
///         amount: transfer and transferFrom return true while leaving every
///         balance unchanged.
contract MockZeroTransferERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}
