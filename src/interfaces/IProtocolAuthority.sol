// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IProtocolAuthority
/// @notice Shared configuration that Glade modules read: the admin address,
///         the compliance authority allowed to set identity tiers, the pause
///         flag, and fee routing.
/// @dev Exposes getters only. Modules read from it but cannot write to it,
///      which leaves a single contract in control of protocol behaviour.
interface IProtocolAuthority {
    function authority() external view returns (address);
    function complianceAuthority() external view returns (address);
    function paused() external view returns (bool);

    /// @notice Address that collects protocol fees. When this is the zero
    ///         address, no module charges a fee.
    function treasury() external view returns (address);

    /// @notice Address of the IFeeSchedule contract, or zero to disable fees.
    ///         Returned as `address` rather than the interface type so that
    ///         callers do not need to import IFeeSchedule.
    function feeSchedule() external view returns (address);
}
