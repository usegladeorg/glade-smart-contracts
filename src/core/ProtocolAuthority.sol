// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IProtocolAuthority} from "../interfaces/IProtocolAuthority.sol";
import "../utils/ProtocolErrors.sol";

/// @title ProtocolAuthority
/// @notice Shared configuration for Glade on Robinhood Chain. It records the
///         admin, the identity attester, the global pause flag, and the fee
///         routing that other modules consult. Coordination is its only job.
///
/// @dev Despite the name, this contract has no custody. It keeps no balances:
///      user funds stay in each account's own wallet, and the sole pooled funds
///      in the system are the per-agent vaults held by {AgentController}. The
///      admin can halt value movement and reassign roles, but has no means of
///      moving anyone's tokens.
///
///      After beta the admin role is meant to move to a Safe multisig. That
///      happens through {updateConfig} or the two-step transfer, so contracts
///      that depend on this one never need redeploying.
contract ProtocolAuthority is IProtocolAuthority {
    /// @notice Raised when {acceptAuthority} is called by an address other than
    ///         the current nominee.
    error NotPendingAuthority();

    /// @notice Raised when {setPause} would leave the pause flag unchanged.
    error PauseUnchanged();

    /// @notice Raised when {setComplianceAuthority} is given the address that
    ///         already holds the role.
    error SameComplianceAuthority();

    /// @notice Current admin. Can reassign roles, toggle the pause, and set
    ///         fee routing.
    address public authority;

    /// @notice Address the admin has proposed as its replacement. Gains nothing
    ///         until it calls {acceptAuthority} itself, so a wrong address can
    ///         never end up as admin by accident.
    address public pendingAuthority;

    /// @notice Account allowed to write KYC results for users. Represents the
    ///         external identity provider (Persona, Onfido, or a similar
    ///         service) reporting back once a verification finishes.
    address public complianceAuthority;

    /// @notice Global kill switch. When true, value-moving calls revert across
    ///         the protocol while identity and agent management keep working.
    ///         This split is by design, since responding to an incident means
    ///         still being able to pause or revoke agents.
    bool public paused;

    /// @notice Recipient of protocol fees. A zero value turns fees off
    ///         everywhere, and that is the default at deployment.
    address public treasury;

    /// @notice Fee schedule contract that settlement modules ask for quotes.
    ///         A zero value turns fees off. Stored untyped; callers cast it to
    ///         IFeeSchedule when they use it.
    address public feeSchedule;

    event ConfigInitialized(address indexed authority, address indexed complianceAuthority);
    event ConfigAuthorityUpdated(address indexed authority, address indexed complianceAuthority);
    event AuthorityTransferStarted(
        address indexed currentAuthority, address indexed pendingAuthority
    );
    event AuthorityTransferAccepted(
        address indexed previousAuthority, address indexed newAuthority
    );
    event ComplianceAuthorityUpdated(
        address indexed previousComplianceAuthority, address indexed complianceAuthority
    );
    event ProtocolPauseToggled(bool paused);
    event FeeConfigUpdated(address indexed treasury, address indexed feeSchedule);

    modifier onlyAuthority() {
        if (msg.sender != authority) revert Unauthorized();
        _;
    }

    /// @param complianceAuthority_ Initial address authorised to record KYC results.
    constructor(address complianceAuthority_) {
        if (complianceAuthority_ == address(0)) revert ZeroAddress();
        authority = msg.sender;
        complianceAuthority = complianceAuthority_;
        emit ConfigInitialized(msg.sender, complianceAuthority_);
    }

    /// @notice Sets a new admin and a new compliance authority together.
    /// @dev Single-step and callable only by the current admin. Suited to
    ///      handing control to a multisig or changing KYC providers while
    ///      every module keeps pointing at this contract.
    function updateConfig(address newAuthority, address newComplianceAuthority)
        external
        onlyAuthority
    {
        if (newAuthority == address(0) || newComplianceAuthority == address(0)) {
            revert ZeroAddress();
        }
        authority = newAuthority;
        complianceAuthority = newComplianceAuthority;
        // A direct replacement cancels any nomination still awaiting acceptance.
        pendingAuthority = address(0);
        emit ConfigAuthorityUpdated(newAuthority, newComplianceAuthority);
    }

    /// @notice Changes only the compliance authority; the admin stays as is.
    /// @dev Going through {updateConfig} for this would force the caller to
    ///      repeat the admin address each time, an avoidable chance for error.
    ///      Any pending admin nomination is left untouched.
    function setComplianceAuthority(address newComplianceAuthority) external onlyAuthority {
        if (newComplianceAuthority == address(0)) revert ZeroAddress();
        // Re-setting the same provider would log a handover that never
        // happened, which is misleading in a compliance audit trail.
        if (newComplianceAuthority == complianceAuthority) revert SameComplianceAuthority();
        address previous = complianceAuthority;
        complianceAuthority = newComplianceAuthority;
        emit ComplianceAuthorityUpdated(previous, newComplianceAuthority);
    }

    /// @notice First half of a two-step admin transfer: records a nominee while
    ///         the current admin keeps full control until {acceptAuthority}.
    /// @dev Having the nominee claim the role itself prevents the classic
    ///      single-step mistake of sending admin rights to an unowned or
    ///      mistyped address. Passing the zero address cancels a pending
    ///      nomination.
    function beginAuthorityTransfer(address newAuthority) external onlyAuthority {
        pendingAuthority = newAuthority;
        emit AuthorityTransferStarted(authority, newAuthority);
    }

    /// @notice Second half of the transfer started by {beginAuthorityTransfer}.
    ///         Callable solely by the pending nominee.
    function acceptAuthority() external {
        if (msg.sender != pendingAuthority) revert NotPendingAuthority();
        address previous = authority;
        authority = msg.sender;
        pendingAuthority = address(0);
        emit AuthorityTransferAccepted(previous, msg.sender);
    }

    /// @notice Turns the global pause on or off.
    /// @dev A repeat call is rejected instead of re-emitting the event. During
    ///      an incident several operators may race to pause, and monitors
    ///      should see one {ProtocolPauseToggled} per real state change.
    function setPause(bool paused_) external onlyAuthority {
        if (paused == paused_) revert PauseUnchanged();
        paused = paused_;
        emit ProtocolPauseToggled(paused_);
    }

    /// @notice Enables or disables protocol fees. Charging needs both a
    ///         recipient and a schedule, so the two must be set together:
    ///         supply both addresses to enable, or zero for both to disable.
    ///         Modules consult this pair to determine whether a fee applies
    ///         and what it comes to.
    /// @param treasury_ Address that receives fees; zero disables fees.
    /// @param feeSchedule_ IFeeSchedule contract used for quotes; zero disables fees.
    function setFeeConfig(address treasury_, address feeSchedule_) external onlyAuthority {
        // Reject a half-configured pair. Modules would quietly treat it as
        // disabled, and an operator is better served by a revert than by
        // fees that silently never apply.
        if ((treasury_ == address(0)) != (feeSchedule_ == address(0))) revert InvalidFeeConfig();
        // Quotes are external calls to the schedule, so a codeless address
        // (for example a wallet pasted by mistake) would make every payment
        // revert. Catch that at configuration time.
        if (feeSchedule_ != address(0) && feeSchedule_.code.length == 0) {
            revert InvalidFeeConfig();
        }
        treasury = treasury_;
        feeSchedule = feeSchedule_;
        emit FeeConfigUpdated(treasury_, feeSchedule_);
    }
}
