// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {AltBn128} from "./AltBn128.sol";
import {IConfidentialTransferVerifier} from "./IConfidentialTransferVerifier.sol";
import "../utils/ProtocolErrors.sol";

/// @title ConfidentialToken
/// @notice Glade's core privacy layer. It wraps an ordinary ERC-20 (USDG in
///         practice) and stores each holder's balance in a form only that
///         holder can decrypt. Amounts are kept as ElGamal ciphertexts over
///         alt_bn128, and an on-chain zero-knowledge proof check confirms every
///         transfer is valid while revealing no figures. Sender and recipient
///         remain visible on-chain; the amount moved does not.
///
/// @dev Lifecycle overview:
///      1. Registration: an account publishes an ElGamal public key, after
///         which it owns a single ciphertext balance `(c1, c2)`.
///      2. {deposit}: the underlying asset is wrapped by adding `amount * G`
///         to `c2` using zero randomness. This is the usual Zether funding
///         step, and it keeps the balance decryptable with the depositor's
///         view key.
///      3. {confidentialTransfer}: the caller supplies a ciphertext of
///         `-amount` under its own key, a ciphertext of `+amount` under the
///         recipient's key, and a proof. The verifier checks that the two
///         encrypt an identical non-negative value and that the sender does
///         not go negative. Each ciphertext is then added to its balance as
///         curve points, so the amount is absent from both calldata and
///         storage.
///      4. {withdraw}: the asset is unwrapped once a proof shows the encrypted
///         balance is large enough.
///
///      Verification is delegated to a separate contract that {setVerifier}
///      can swap, so new circuits never require moving balances.
contract ConfidentialToken is ReentrancyGuard {
    using SafeTransferLib for IERC20;
    using AltBn128 for AltBn128.Point;

    /// @notice Raised by deposit, withdraw, and transfer calls made while the
    ///         layer's freeze is on.
    error TokenPaused();

    /// @notice Raised when {acceptAuthority} is called by an address other
    ///         than the current nominee.
    error NotPendingAuthority();

    /// @notice Raised when {setVerifier} is given the verifier that is
    ///         already active.
    error SameVerifier();

    /// @notice Raised when the sender and recipient of a confidential transfer
    ///         are the same account. Both ciphertexts would land on one
    ///         balance, wasting the proof, and a dedicated error tells clients
    ///         exactly what happened where the generic {Unauthorized} did not.
    error SelfTransfer();

    /// @notice Raised when {setPaused} would leave the freeze flag unchanged.
    error PauseUnchanged();

    struct Ciphertext {
        AltBn128.Point c1;
        AltBn128.Point c2;
    }

    /// @notice Underlying ERC-20 held by this wrapper; on Robinhood Chain this
    ///         is USDG.
    IERC20 public immutable asset;

    /// @notice Address allowed to rotate the verifier and toggle the freeze.
    address public authority;

    /// @notice Address nominated to take over {authority}. It gains no power
    ///         until it calls {acceptAuthority}, which guards against handing
    ///         verifier and freeze control to a mistyped address.
    address public pendingAuthority;

    /// @notice Contract that validates transfer and withdrawal proofs.
    IConfidentialTransferVerifier public verifier;

    /// @notice ElGamal public key registered by each account.
    mapping(address => AltBn128.Point) internal _publicKey;
    mapping(address => bool) public registered;

    /// @notice Ciphertext balance for each account.
    mapping(address => Ciphertext) internal _balance;

    /// @notice Running total of underlying asset wrapped into this contract,
    ///         used to demonstrate full collateralisation.
    uint256 public totalWrapped;

    /// @notice Freeze flag scoped to this contract only. When true, deposit,
    ///         withdraw, and transfer revert. Registration and verifier changes
    ///         still succeed, so a faulty verifier can be replaced, or an issue
    ///         with the underlying asset can be waited on, without locking
    ///         anyone out.
    bool public paused;

    event Registered(address indexed account, uint256 pkX, uint256 pkY);
    event Deposited(address indexed account, uint256 amount);
    event ConfidentialTransfer(address indexed from, address indexed to);
    event Withdrawn(address indexed account, uint256 amount);
    event VerifierUpdated(address indexed previousVerifier, address indexed verifier);
    event PauseToggled(bool paused);
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

    modifier whenNotPaused() {
        if (paused) revert TokenPaused();
        _;
    }

    constructor(IERC20 asset_, IConfidentialTransferVerifier verifier_, address authority_) {
        if (
            address(asset_) == address(0) || address(verifier_) == address(0)
                || authority_ == address(0)
        ) revert ZeroAddress();
        asset = asset_;
        verifier = verifier_;
        authority = authority_;
    }

    // =========================================================================
    //                              Registration
    // =========================================================================

    /// @notice Stores the caller's ElGamal public key and gives it a zero
    ///         encrypted balance. Must be called once before depositing.
    /// @dev Registration is the cheapest place to confirm the key is a valid
    ///      curve point, so the check happens here. An invalid key would make
    ///      every ciphertext sent to this account undecryptable and would
    ///      inject off-curve values into the balance arithmetic forever.
    /// @param pkX Public key x coordinate.
    /// @param pkY Public key y coordinate.
    function register(uint256 pkX, uint256 pkY) external {
        if (registered[msg.sender]) revert AccountAlreadyRegistered();
        if (!AltBn128.isOnCurve(AltBn128.Point(pkX, pkY))) revert InvalidPublicKey();

        _publicKey[msg.sender] = AltBn128.Point(pkX, pkY);
        registered[msg.sender] = true;
        // No balance write is needed: an all-zero ciphertext decrypts to zero.
        emit Registered(msg.sender, pkX, pkY);
    }

    // =========================================================================
    //                           Wrap and unwrap
    // =========================================================================

    /// @notice Pulls `amount` of the underlying asset from the caller and adds
    ///         it to the caller's ciphertext balance as `amount * G` in the
    ///         message component, with no randomness, so the caller's view key
    ///         can still decrypt it.
    /// @param amount Quantity of the underlying asset to wrap.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (!registered[msg.sender]) revert AccountNotRegistered();
        if (amount == 0) revert InvalidSpendAmount();

        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - before;
        // Guard against fee-on-transfer tokens that deliver nothing, which
        // would otherwise emit Deposited without crediting anything.
        if (received == 0) revert InvalidSpendAmount();

        Ciphertext storage bal = _balance[msg.sender];
        bal.c2 = bal.c2.add(AltBn128.encode(received));
        totalWrapped += received;

        emit Deposited(msg.sender, received);
    }

    /// @notice Sends `amount` of the underlying asset back to the caller and
    ///         reduces the encrypted balance accordingly.
    /// @dev After the proof establishes that the ciphertext balance is at
    ///      least `amount`, `amount * G` is subtracted from the message
    ///      component and the tokens are transferred out.
    /// @param amount Quantity to unwrap. This value is deliberately public,
    ///        since the outgoing ERC-20 transfer reveals it anyway.
    /// @param proof Proof of sufficient balance for the withdrawal.
    /// @param publicSignals Public inputs for the circuit, laid out as the
    ///        verifier defines.
    function withdraw(uint256 amount, bytes calldata proof, uint256[] calldata publicSignals)
        external
        nonReentrant
        whenNotPaused
    {
        if (!registered[msg.sender]) revert AccountNotRegistered();
        if (amount == 0) revert InvalidSpendAmount();
        if (!verifier.verifyWithdraw(proof, publicSignals)) revert ProofRejected();
        // Redundant under a correct verifier. It costs little and converts a
        // potential underflow panic into a named error should a faulty proof
        // ever be accepted.
        if (amount > totalWrapped) revert ExceedsWrappedSupply();

        Ciphertext storage bal = _balance[msg.sender];
        bal.c2 = bal.c2.add(AltBn128.encode(amount).negate());
        totalWrapped -= amount;

        asset.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // =========================================================================
    //                          Confidential transfer
    // =========================================================================

    /// @notice Moves a hidden amount from the caller to `to`. No plaintext
    ///         value is passed in; the two ciphertext deltas encode it and the
    ///         proof binds them together.
    /// @param to Destination account; it has to be registered already.
    /// @param senderDelta Ciphertext of `-amount` under the caller's key.
    /// @param recipientDelta Ciphertext of `+amount` under the key of `to`.
    /// @param proof Shows both deltas hide the same value and that the
    ///        caller's balance stays non-negative.
    /// @param publicSignals Public inputs for the circuit, laid out as the
    ///        verifier defines.
    function confidentialTransfer(
        address to,
        Ciphertext calldata senderDelta,
        Ciphertext calldata recipientDelta,
        bytes calldata proof,
        uint256[] calldata publicSignals
    ) external nonReentrant whenNotPaused {
        if (!registered[msg.sender]) revert AccountNotRegistered();
        if (!registered[to]) revert AccountNotRegistered();
        if (to == msg.sender) revert SelfTransfer();
        if (!verifier.verifyTransfer(proof, publicSignals)) revert ProofRejected();

        Ciphertext storage from = _balance[msg.sender];
        from.c1 = from.c1.add(senderDelta.c1);
        from.c2 = from.c2.add(senderDelta.c2);

        Ciphertext storage recv = _balance[to];
        recv.c1 = recv.c1.add(recipientDelta.c1);
        recv.c2 = recv.c2.add(recipientDelta.c2);

        emit ConfidentialTransfer(msg.sender, to);
    }

    // =========================================================================
    //                              Authority
    // =========================================================================

    /// @notice Installs a new proof verifier, usually when circuits are
    ///         upgraded.
    /// @dev The event carries both the old and new verifier addresses. This is
    ///      the highest-impact action available to the authority, so a
    ///      monitor should be able to read the whole change from a single log
    ///      entry without querying prior state.
    /// @param newVerifier Verifier contract to activate.
    function setVerifier(IConfidentialTransferVerifier newVerifier) external onlyAuthority {
        if (address(newVerifier) == address(0)) revert ZeroAddress();
        if (newVerifier == verifier) revert SameVerifier();
        address previous = address(verifier);
        verifier = newVerifier;
        emit VerifierUpdated(previous, address(newVerifier));
    }

    /// @notice Turns the freeze on deposits, withdrawals, and transfers on or
    ///         off. Registration and {setVerifier} intentionally stay usable
    ///         so the contract can be fixed in place instead of replaced.
    /// @param paused_ Desired freeze state.
    function setPaused(bool paused_) external onlyAuthority {
        if (paused == paused_) revert PauseUnchanged();
        paused = paused_;
        emit PauseToggled(paused_);
    }

    /// @notice Proposes a successor authority while the current one keeps the
    ///         role. The successor finalises the change with {acceptAuthority}.
    /// @dev Mirrors the two-step pattern in {ProtocolAuthority}. Because this
    ///      role governs the verifier and the freeze, sending it to an address
    ///      with no key holder could never be undone; requiring the nominee to
    ///      sign closes that gap. Passing the zero address cancels a pending
    ///      nomination.
    /// @param newAuthority Proposed successor, or zero to cancel.
    function beginAuthorityTransfer(address newAuthority) external onlyAuthority {
        // Nominating the sitting authority would leave a handoff open that
        // changes nothing when accepted.
        if (newAuthority == authority) revert AlreadyAuthority();
        pendingAuthority = newAuthority;
        emit AuthorityTransferStarted(authority, newAuthority);
    }

    /// @notice Completes a handoff started by {beginAuthorityTransfer}; only
    ///         the nominee may call it.
    function acceptAuthority() external {
        if (msg.sender != pendingAuthority) revert NotPendingAuthority();
        address previous = authority;
        authority = msg.sender;
        pendingAuthority = address(0);
        emit AuthorityTransferAccepted(previous, msg.sender);
    }

    // =========================================================================
    //                                Views
    // =========================================================================

    function publicKeyOf(address account) external view returns (uint256 x, uint256 y) {
        AltBn128.Point storage p = _publicKey[account];
        return (p.x, p.y);
    }

    /// @notice Returns the public keys for several accounts in one call, in
    ///         the order given. A sender has to encrypt each recipient's delta
    ///         under that recipient's key, so a client preparing transfers to
    ///         many accounts can fetch every key at once. Unregistered accounts
    ///         come back as (0, 0); check {registered} before sending to them.
    function publicKeysOf(address[] calldata accounts)
        external
        view
        returns (AltBn128.Point[] memory keys)
    {
        keys = new AltBn128.Point[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            keys[i] = _publicKey[accounts[i]];
        }
    }

    /// @notice True when the contract's underlying balance is at least
    ///         {totalWrapped}. Direct ERC-20 transfers into the contract can
    ///         make it exceed that total, which does no harm; a shortfall is
    ///         what monitoring should alert on.
    function isFullyBacked() external view returns (bool) {
        return asset.balanceOf(address(this)) >= totalWrapped;
    }

    /// @notice Returns an account's ciphertext balance as stored. Decrypting
    ///         it requires the holder's view key, which never touches this
    ///         contract.
    function encryptedBalanceOf(address account) external view returns (Ciphertext memory) {
        return _balance[account];
    }
}
