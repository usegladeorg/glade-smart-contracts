// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IFeeSchedule
/// @notice Interface to Glade's one source of fee pricing. Contracts that
///         transfer value compute fees through it, and clients query the same
///         function to show a user the rate ahead of any commitment.
interface IFeeSchedule {
    /// @notice Computes the fee `payer` would owe for transferring `amount`.
    /// @param payer The account that bears the fee. Rates are uniform for now,
    ///        and the argument exists so the signature need not change later.
    /// @param amount Gross transfer size in settlement-token base units.
    /// @return feeAmount Fee due, expressed in the same base units.
    /// @return effectiveBps Realised rate in basis points, intended for display.
    function quoteFee(address payer, uint256 amount)
        external
        view
        returns (uint256 feeAmount, uint256 effectiveBps);
}
