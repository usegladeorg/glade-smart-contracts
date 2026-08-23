// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IERC20
/// @notice Only the ERC-20 functions Glade calls, used for USDG and any other
///         settlement token handled on Robinhood Chain. The interface is
///         intentionally small, since each extra function is one more
///         assumption about third-party token code.
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}
