// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IProtocolAuthority} from "../interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../interfaces/IAccountRegistry.sol";
import "../utils/ProtocolErrors.sol";

/// @title AccountRegistry
/// @notice Identity layer for Glade. A wallet may open one account record, and
///         that record claims a `.glade` handle, which lets senders pay
///         gwen.glade rather than copy a long hex address.
///
/// @dev This contract never holds funds and never stops a transfer. Glade's
///      confidentiality covers amounts only, not who someone is, so the record
///      is checked when it is created and the KYC tier stored here is read by
///      whichever module applies limits. Stored handles are lowercase and carry
///      neither a leading at-sign nor the `.glade` suffix. {fullHandle} appends
///      the suffix at read time, which avoids spending storage on it.
contract AccountRegistry is IAccountRegistry {
    /// @notice Reverts when the requested account kind matches the current one.
    error SameAccountKind();

    /// @notice Reverts when the compliance authority tries to set a KYC tier
    ///         that the account is already on.
    error SameKycTier();

    enum AccountKind {
        Personal,
        Business,
        AgentOperator
    }

    struct Profile {
        address owner;
        string handle;
        KycTier kycTier;
        AccountKind accountKind;
        uint64 createdAt;
        uint64 updatedAt;
        bool exists;
    }

    uint256 internal constant MAX_HANDLE_LEN = 32;
    string internal constant HANDLE_SUFFIX = ".glade";

    IProtocolAuthority public immutable protocol;

    /// @notice Maps each owning wallet to its single account record.
    mapping(address => Profile) internal _profiles;

    /// @notice Maps the keccak hash of a handle to the wallet that owns it.
    ///         Clients mostly ask two things (is the name taken, and which
    ///         wallet does it resolve to), and indexing by handle answers each
    ///         with one storage read, so paying by handle stays fast.
    mapping(bytes32 => address) internal _handleOwner;

    event ProfileCreated(
        address indexed owner, string handle, AccountKind accountKind, uint256 timestamp
    );
    event KycTierUpdated(address indexed owner, KycTier kycTier, uint256 timestamp);
    event AccountKindChanged(
        address indexed owner, AccountKind previousKind, AccountKind newKind, uint256 timestamp
    );
    event HandleChanged(
        address indexed owner, string previousHandle, string newHandle, uint256 timestamp
    );

    constructor(IProtocolAuthority protocol_) {
        if (address(protocol_) == address(0)) revert ZeroAddress();
        protocol = protocol_;
    }

    /* =========================== Account writes =========================== */

    /// @notice Creates the caller's account and claims the given `.glade`
    ///         handle for it. Every new record starts as {KycTier.Unverified}
    ///         until the compliance authority upgrades it after an off-chain check.
    /// @param handle Bare handle: lowercase, without an at-sign or `.glade`.
    /// @param accountKind Whether this is a personal, business, or agent operator account.
    function createProfile(string calldata handle, AccountKind accountKind) external {
        if (_profiles[msg.sender].exists) revert ProfileAlreadyExists();
        _checkHandle(handle);

        bytes32 key = keccak256(bytes(handle));
        if (_handleOwner[key] != address(0)) revert HandleAlreadyTaken();

        _handleOwner[key] = msg.sender;
        _profiles[msg.sender] = Profile({
            owner: msg.sender,
            handle: handle,
            kycTier: KycTier.Unverified,
            accountKind: accountKind,
            createdAt: uint64(block.timestamp),
            updatedAt: uint64(block.timestamp),
            exists: true
        });

        emit ProfileCreated(msg.sender, handle, accountKind, block.timestamp);
    }

    /// @notice Swaps the caller's `.glade` handle for a new one and frees the
    ///         previous name so others can claim it.
    /// @dev Nothing except the handle is touched: the KYC tier, account kind,
    ///      creation timestamp and owning wallet all stay as they were. Indexers
    ///      that cached the old name should listen for {HandleChanged} and
    ///      resolve again.
    /// @param newHandle Bare handle, validated by the same rules used at account creation.
    function changeHandle(string calldata newHandle) external {
        Profile storage p = _profiles[msg.sender];
        if (!p.exists) revert ProfileNotFound();
        _checkHandle(newHandle);

        bytes32 newKey = keccak256(bytes(newHandle));
        // Rejects handles owned by another wallet, and also the caller's current one.
        if (_handleOwner[newKey] != address(0)) revert HandleAlreadyTaken();

        string memory previous = p.handle;
        delete _handleOwner[keccak256(bytes(previous))];
        _handleOwner[newKey] = msg.sender;
        p.handle = newHandle;
        p.updatedAt = uint64(block.timestamp);

        emit HandleChanged(msg.sender, previous, newHandle, block.timestamp);
    }

    /// @notice Lets the caller change the kind on their own record, e.g. after
    ///         forming a company or beginning to run agents. Handle, tier and
    ///         creation time are preserved. The kind is informational, read by
    ///         UIs and limit logic, and grants no extra rights.
    function setAccountKind(AccountKind accountKind) external {
        Profile storage p = _profiles[msg.sender];
        if (!p.exists) revert ProfileNotFound();
        if (p.accountKind == accountKind) revert SameAccountKind();

        AccountKind previous = p.accountKind;
        p.accountKind = accountKind;
        p.updatedAt = uint64(block.timestamp);
        emit AccountKindChanged(msg.sender, previous, accountKind, block.timestamp);
    }

    /// @notice Records the result of identity verification performed off-chain.
    /// @dev Callable only by the compliance authority that the protocol
    ///      contract reports. No funds move and no action is blocked here; the
    ///      tier is simply made available to limit checks in other modules.
    function setKycTier(address owner, KycTier kycTier) external {
        if (msg.sender != protocol.complianceAuthority()) {
            revert UnauthorizedComplianceAuthority();
        }
        Profile storage p = _profiles[owner];
        if (!p.exists) revert ProfileNotFound();
        // Writing the same tier again would refresh updatedAt and log an event
        // with no real change behind it, cluttering the audit history.
        if (p.kycTier == kycTier) revert SameKycTier();

        p.kycTier = kycTier;
        p.updatedAt = uint64(block.timestamp);
        emit KycTierUpdated(owner, kycTier, block.timestamp);
    }

    /* ================================ Views ================================ */

    /// @inheritdoc IAccountRegistry
    function isRegistered(address owner) external view returns (bool) {
        return _profiles[owner].exists;
    }

    /// @inheritdoc IAccountRegistry
    function handleOf(address owner) external view returns (string memory) {
        return _profiles[owner].handle;
    }

    /// @inheritdoc IAccountRegistry
    function kycTierOf(address owner) external view returns (KycTier) {
        return _profiles[owner].kycTier;
    }

    /// @notice Returns the full profile stored for `owner`.
    function profileOf(address owner) external view returns (Profile memory) {
        return _profiles[owner];
    }

    /// @notice Looks up a profile directly from its `.glade` handle. A payment
    ///         screen needs the kind and tier right after resolving a name, so
    ///         returning everything in one call removes an extra request per
    ///         recipient. For a handle nobody owns, the result is a zeroed
    ///         struct whose `exists` flag is false.
    function profileByHandle(string calldata handle) external view returns (Profile memory) {
        return _profiles[_handleOwner[keccak256(bytes(handle))]];
    }

    /// @notice Returns the wallet that owns a `.glade` handle, or address(0) if
    ///         the handle is unclaimed.
    function resolveHandle(string calldata handle) external view returns (address) {
        return _handleOwner[keccak256(bytes(handle))];
    }

    /// @notice True when `handle` is valid in length and characters and no
    ///         wallet owns it yet. Sign-up forms can call this as the user
    ///         types, so clients do not need to duplicate the validation rules.
    function handleAvailable(string calldata handle) external view returns (bool) {
        uint256 len = bytes(handle).length;
        if (len == 0 || len > MAX_HANDLE_LEN) return false;
        if (!_isValidHandle(handle)) return false;
        return _handleOwner[keccak256(bytes(handle))] == address(0);
    }

    /// @notice Display form of the owner's handle with the suffix attached, such as `gwen.glade`.
    function fullHandle(address owner) external view returns (string memory) {
        return string.concat(_profiles[owner].handle, HANDLE_SUFFIX);
    }

    /* ============================== Internals ============================== */

    /// @dev Shared validation for every write path that sets a handle, which
    ///      keeps account creation and handle changes on identical rules.
    function _checkHandle(string calldata handle) internal pure {
        uint256 len = bytes(handle).length;
        if (len == 0 || len > MAX_HANDLE_LEN) revert InvalidHandleLength();
        if (!_isValidHandle(handle)) revert InvalidHandleCharacters();
    }

    /// @dev Accepts only `a` to `z`, `0` to `9`, and `_`. Keeping to this set
    ///      means a handle can go into a payment link or QR code as is, with no
    ///      escaping or normalisation step.
    function _isValidHandle(string calldata handle) internal pure returns (bool) {
        bytes memory b = bytes(handle);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) // lowercase letter
                || (c >= 0x30 && c <= 0x39) // decimal digit
                || c == 0x5f; // underscore
            if (!ok) return false;
        }
        return true;
    }
}
