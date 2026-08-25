// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ReentrancyGuard
/// @notice A single-slot lock that stops a token callback from re-entering a
///         guarded function before the first call finishes moving funds. Used
///         on every path that pays out from a vault or a confidential balance.
abstract contract ReentrancyGuard {
    uint256 private constant _OPEN = 1;
    uint256 private constant _CLOSED = 2;

    uint256 private _gate = _OPEN;

    error Reentrancy();

    modifier nonReentrant() {
        if (_gate == _CLOSED) revert Reentrancy();
        _gate = _CLOSED;
        _;
        _gate = _OPEN;
    }
}
