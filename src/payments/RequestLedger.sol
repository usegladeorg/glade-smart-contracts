// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IProtocolAuthority} from "../interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../interfaces/IAccountRegistry.sol";
import {IFeeSchedule} from "./IFeeSchedule.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import "../utils/ProtocolErrors.sol";

/// @title RequestLedger
/// @notice On-chain storage for Glade payment requests, the data each shared
///         link or QR code points to.
///
/// @dev A requester creates an entry naming a token and amount, distributes the
///      link, and the person who opens it pays exactly that. Because Glade is
///      private by default, the amount itself can be hidden: the request stores
///      a commitment instead of the number, and {fulfill} checks the payer's
///      stated amount against it before transferring anything.
///
///      Settlement here uses a standard ERC-20 transfer. To keep the amount
///      hidden end to end, a client pairs a confidential request with a
///      {ConfidentialToken} transfer at payment time; that pairing happens off
///      this contract. This contract handles request state and the commitment
///      check only, and performs no encryption.
contract RequestLedger is ReentrancyGuard {
    using SafeTransferLib for IERC20;

    enum RequestStatus {
        Open,
        Fulfilled,
        Cancelled
    }

    struct Request {
        address requester; // account that created the request
        address receiver; // recipient of the payment
        address token;
        bool isConfidential;
        uint256 amount; // public amount, or 0 for confidential requests
        bytes32 amountCommitment; // hash the payer's amount and blinding must match
        bytes32 memoHash; // digest of the encrypted memo
        RequestStatus status;
        uint64 createdAt;
        uint64 expiresAt;
        bool exists;
        address payer; // address that paid, unset while open
        uint64 fulfilledAt; // payment timestamp, unset while open
    }

    IProtocolAuthority public immutable protocol;
    IAccountRegistry public immutable registry;

    uint256 public requestCount;
    mapping(uint256 => Request) internal _requests;

    /// @notice Each requester's request ids in creation order, letting a wallet
    ///         enumerate its links without scanning events.
    mapping(address => uint256[]) internal _requestsByRequester;

    event PaymentRequestCreated(
        uint256 indexed requestId,
        address indexed requester,
        address token,
        bool isConfidential,
        uint256 amount,
        uint64 expiresAt,
        uint256 timestamp
    );
    event PaymentRequestFulfilled(
        uint256 indexed requestId, address indexed payer, uint256 amount, uint256 timestamp
    );
    event PaymentRequestCancelled(uint256 indexed requestId, uint256 timestamp);
    event PaymentRequestExtended(
        uint256 indexed requestId, uint64 previousExpiry, uint64 newExpiry, uint256 timestamp
    );
    event ProtocolFeeCharged(
        uint256 indexed requestId, address indexed treasury, uint256 fee, uint256 timestamp
    );

    constructor(IProtocolAuthority protocol_, IAccountRegistry registry_) {
        if (address(protocol_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        protocol = protocol_;
        registry = registry_;
    }

    /// @notice Creates a payment request that can be distributed as a link or QR code.
    /// @dev For a confidential request, set `isConfidential` to true, `amount`
    ///      to 0, and supply a nonzero `amountCommitment`. The requester shares
    ///      the amount and blinding value privately (usually inside the
    ///      encrypted memo), and the payer passes both to {fulfill}.
    /// @param receiver Address that receives payment. It can differ from the
    ///        requester, for example a company treasury collecting on its behalf.
    function create(
        address receiver,
        address token,
        bool isConfidential,
        uint256 amount,
        bytes32 amountCommitment,
        bytes32 memoHash,
        uint64 expiresAt
    ) external returns (uint256 requestId) {
        if (!registry.isRegistered(msg.sender)) revert ProfileNotFound();
        if (receiver == address(0) || token == address(0)) revert ZeroAddress();
        // Reject a token address without deployed code (for instance an EOA
        // entered by mistake), because such a request could never be settled.
        if (token.code.length == 0) revert InvalidToken();
        if (expiresAt <= block.timestamp) revert InvalidExpiry();
        if (!isConfidential && amount == 0) revert InvalidSpendAmount();
        // Without a commitment, fulfill would check every payer against a zero
        // hash and fail, leaving the request permanently unpayable.
        if (isConfidential && amountCommitment == bytes32(0)) revert MissingCommitment();

        requestId = ++requestCount;
        _requests[requestId] = Request({
            requester: msg.sender,
            receiver: receiver,
            token: token,
            isConfidential: isConfidential,
            amount: isConfidential ? 0 : amount,
            amountCommitment: isConfidential ? amountCommitment : bytes32(0),
            memoHash: memoHash,
            status: RequestStatus.Open,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            exists: true,
            payer: address(0),
            fulfilledAt: 0
        });
        _requestsByRequester[msg.sender].push(requestId);

        emit PaymentRequestCreated(
            requestId,
            msg.sender,
            token,
            isConfidential,
            isConfidential ? 0 : amount,
            expiresAt,
            block.timestamp
        );
    }

    /// @notice Settles an open request and marks it fulfilled.
    /// @dev Public requests require `amount` to match the stored value.
    ///      Confidential requests require the privately shared amount and
    ///      blinding value, and verify that `keccak256(amount, blinding)`
    ///      equals the stored commitment. A payer using the wrong amount is
    ///      rejected even though the true amount was never published on-chain.
    function fulfill(uint256 requestId, uint256 amount, bytes32 blinding) external nonReentrant {
        if (protocol.paused()) revert ProtocolPaused();

        Request storage r = _requests[requestId];
        if (r.status != RequestStatus.Open) revert RequestNotOpen();
        if (block.timestamp >= r.expiresAt) revert RequestExpired();
        // Public requests are never stored with a zero amount, yet a commitment
        // can encode zero, and paying it would close the request with nothing
        // transferred. Block it here just as {create} blocks a zero public amount.
        if (amount == 0) revert InvalidSpendAmount();

        if (r.isConfidential) {
            if (keccak256(abi.encodePacked(amount, blinding)) != r.amountCommitment) {
                revert RequestCommitmentMismatch();
            }
        } else if (amount != r.amount) {
            revert RequestAmountMismatch();
        }

        r.status = RequestStatus.Fulfilled;
        r.payer = msg.sender;
        r.fulfilledAt = uint64(block.timestamp);

        // The payer is the protocol user here, so they cover the fee in
        // addition to the amount and the receiver gets the full sum. If no fee
        // schedule or treasury is configured, the fee is zero and only the
        // main transfer runs.
        (uint256 fee, address treasury) = _quoteFee(msg.sender, amount);

        IERC20(r.token).safeTransferFrom(msg.sender, r.receiver, amount);
        if (fee > 0) {
            IERC20(r.token).safeTransferFrom(msg.sender, treasury, fee);
            emit ProtocolFeeCharged(requestId, treasury, fee, block.timestamp);
        }

        emit PaymentRequestFulfilled(requestId, msg.sender, amount, block.timestamp);
    }

    /// @notice Previews the cost to `payer` of settling a request for
    ///         `amount`: the fee charged on top and the sum the token allowance
    ///         must cover. Confidential amounts are not stored, so the caller
    ///         passes the amount in directly.
    function quotePayment(address payer, uint256 amount)
        external
        view
        returns (uint256 fee, uint256 total)
    {
        (fee,) = _quoteFee(payer, amount);
        total = amount + fee;
    }

    /// @dev Computes the fee and treasury for a payment. Yields zero values when
    ///      either the fee schedule or the treasury is unset.
    function _quoteFee(address payer, uint256 amount)
        internal
        view
        returns (uint256 fee, address treasury)
    {
        address schedule = protocol.feeSchedule();
        treasury = protocol.treasury();
        if (schedule == address(0) || treasury == address(0)) return (0, address(0));
        (fee,) = IFeeSchedule(schedule).quoteFee(payer, amount);
    }

    /// @notice Moves an open request's expiry to a later time, so a link near
    ///         its deadline keeps the same id and payers can still use what
    ///         they were sent. Restricted to the requester, accepts only a
    ///         later timestamp, and works only on requests that are open and
    ///         not yet expired. An expired request cannot be revived.
    function extendExpiry(uint256 requestId, uint64 newExpiresAt) external {
        Request storage r = _requests[requestId];
        if (r.requester != msg.sender) revert Unauthorized();
        if (r.status != RequestStatus.Open) revert RequestNotOpen();
        if (block.timestamp >= r.expiresAt) revert RequestExpired();
        if (newExpiresAt <= r.expiresAt) revert InvalidExpiry();

        uint64 previous = r.expiresAt;
        r.expiresAt = newExpiresAt;
        emit PaymentRequestExtended(requestId, previous, newExpiresAt, block.timestamp);
    }

    /// @notice Cancels an unpaid request. Callable by the requester alone.
    function cancel(uint256 requestId) external {
        Request storage r = _requests[requestId];
        if (r.requester != msg.sender) revert Unauthorized();
        if (r.status != RequestStatus.Open) revert RequestNotOpen();

        r.status = RequestStatus.Cancelled;
        emit PaymentRequestCancelled(requestId, block.timestamp);
    }

    function getRequest(uint256 requestId) external view returns (Request memory) {
        return _requests[requestId];
    }

    /// @notice Loads several requests in one call, in the order given. A
    ///         wallet usually pages ids out of {requestIdsOf} and then needs
    ///         every record on that page, so this saves one RPC round trip per
    ///         link. Unknown ids come back as zeroed structs with `exists`
    ///         set to false, matching {getRequest}.
    function getRequests(uint256[] calldata requestIds)
        external
        view
        returns (Request[] memory requests)
    {
        requests = new Request[](requestIds.length);
        for (uint256 i; i < requestIds.length; ++i) {
            requests[i] = _requests[requestIds[i]];
        }
    }

    /// @notice Number of requests created by `requester`.
    function requestCountOf(address requester) external view returns (uint256) {
        return _requestsByRequester[requester].length;
    }

    /// @notice All request ids created by `requester`, in creation order. Use
    ///         {getRequest} on each to display the wallet's links.
    function requestIdsOf(address requester) external view returns (uint256[] memory) {
        return _requestsByRequester[requester];
    }

    /// @notice Paginated version of the list above: up to `limit` ids starting
    ///         at index `offset`, in creation order. High-volume business
    ///         accounts can exceed what one RPC response holds for the full
    ///         list, so clients page through by increasing `offset` until they
    ///         receive fewer than `limit` ids.
    function requestIdsOf(address requester, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page)
    {
        uint256[] storage all = _requestsByRequester[requester];
        uint256 total = all.length;
        if (offset >= total) return new uint256[](0);

        // Checking `limit` against the remaining count before any addition
        // means a caller can pass type(uint256).max to request the remainder
        // without triggering an arithmetic overflow.
        uint256 end = limit > total - offset ? total : offset + limit;

        page = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = all[i];
        }
    }

    /// @notice True if the request exists, is still open, and has not passed
    ///         its expiry. Clients can call this before showing a pay button
    ///         instead of duplicating the checks in {fulfill}.
    function isFulfillable(uint256 requestId) external view returns (bool) {
        Request storage r = _requests[requestId];
        return r.exists && r.status == RequestStatus.Open && block.timestamp < r.expiresAt;
    }
}
