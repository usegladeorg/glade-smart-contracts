// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IFeeSchedule} from "./IFeeSchedule.sol";
import "../utils/ProtocolErrors.sol";

/// @title FeeSchedule
/// @notice Glade's fee configuration. Value-moving contracts price transfers
///         by calling {quoteFee}, and the app and SDK call that very view to
///         display a user's current rate, so the quoted and charged figures
///         always come from identical logic.
///
/// @dev Rates are expressed in basis points (one bps equals 0.01%):
///
///        gross     = (amount * baseFeeBps) / BPS      // BPS is 10_000
///        feeAmount = feeCap == 0 ? gross : min(gross, feeCap)
///
///      Both `amount` and `feeCap` use the settlement token's base units. The
///      initial values target a stablecoin with 6 decimals: a 0.10% rate with
///      a 5 USDG ceiling.
contract FeeSchedule is IFeeSchedule {
    /// @notice Reverts when {acceptAuthority} is called by an address other
    ///         than the pending authority.
    error NotPendingAuthority();

    /// @notice Reverts when {setSchedule} is given the rate and cap already
    ///         in effect.
    error ScheduleUnchanged();

    uint256 internal constant BPS = 10_000;

    /// @notice Upper bound on `baseFeeBps`, equal to 1%. Since payers bear the
    ///         fee on every transfer, a mistyped rate update is rejected at
    ///         this point instead of reaching users.
    uint16 public constant MAX_BASE_FEE_BPS = 100;

    /// @notice Address allowed to change the schedule, normally the protocol multisig.
    address public authority;

    /// @notice Proposed next authority. It has no power until it calls
    ///         {acceptAuthority}, which protects the fee-setting role from
    ///         being handed to a mistyped address.
    address public pendingAuthority;

    /// @notice Fee rate charged on each transfer, expressed in bps.
    uint16 public baseFeeBps;

    /// @notice Maximum fee per transfer in settlement-token base units, or 0
    ///         for no maximum.
    uint256 public feeCap;

    event FeeScheduleUpdated(uint16 baseFeeBps, uint256 feeCap);
    event AuthorityTransferStarted(
        address indexed currentAuthority, address indexed pendingAuthority
    );
    event AuthorityTransferAccepted(
        address indexed previousAuthority, address indexed newAuthority
    );

    modifier onlyAuthority() {
        if (msg.sender != authority) revert Unauthorized();
        _;
    }

    constructor(address authority_) {
        if (authority_ == address(0)) revert ZeroAddress();
        authority = authority_;

        // Initial schedule: 10 bps, capped at 5_000_000 base units, which is
        // 5 USDG for a 6-decimal token.
        baseFeeBps = 10;
        feeCap = 5_000_000;
    }

    /* ------------------------------- Quoting ------------------------------- */

    /// @inheritdoc IFeeSchedule
    function quoteFee(address, uint256 amount)
        external
        view
        returns (uint256 feeAmount, uint256 effectiveBps)
    {
        uint256 gross = (amount * baseFeeBps) / BPS;
        feeAmount = (feeCap != 0 && gross > feeCap) ? feeCap : gross;
        effectiveBps = amount == 0 ? 0 : (feeAmount * BPS) / amount;
    }

    /* ---------------------------- Configuration ---------------------------- */

    /// @notice Replaces both the base rate and the fee cap.
    function setSchedule(uint16 baseFeeBps_, uint256 feeCap_) external onlyAuthority {
        if (baseFeeBps_ > MAX_BASE_FEE_BPS) revert InvalidFeeConfig();
        // A repeat of the live schedule would still emit FeeScheduleUpdated,
        // and anyone watching fee changes would read it as a real update.
        if (baseFeeBps_ == baseFeeBps && feeCap_ == feeCap) revert ScheduleUnchanged();
        baseFeeBps = baseFeeBps_;
        feeCap = feeCap_;
        emit FeeScheduleUpdated(baseFeeBps_, feeCap_);
    }

    /// @notice Proposes a new authority while the current one keeps its
    ///         rights. The handoff completes only when the proposed address
    ///         calls {acceptAuthority}.
    /// @dev Matches the propose-then-accept pattern used by the protocol's
    ///      other admin roles, so operators follow a single procedure. Passing
    ///      address(0) cancels a pending proposal.
    function beginAuthorityTransfer(address newAuthority) external onlyAuthority {
        pendingAuthority = newAuthority;
        emit AuthorityTransferStarted(authority, newAuthority);
    }

    /// @notice Completes a handoff started with {beginAuthorityTransfer}.
    function acceptAuthority() external {
        if (msg.sender != pendingAuthority) revert NotPendingAuthority();
        address previous = authority;
        authority = msg.sender;
        pendingAuthority = address(0);
        emit AuthorityTransferAccepted(previous, msg.sender);
    }
}
