// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAccountRegistry} from "../interfaces/IAccountRegistry.sol";
import "../utils/ProtocolErrors.sol";

/// @title DisclosureLog
/// @notice Minimal, append-only evidence that an account disclosed a
///         confidential transfer to someone.
///
/// @dev Glade's confidential transfers keep amounts private from outside
///      observers, but both parties can see them, and so can any auditor the
///      account holder chooses to share with. The disclosure proof exposing a
///      decrypted amount is generated client-side from the view key and is
///      never submitted here. This contract stores only a timestamped receipt
///      stating that an account issued a disclosure for a given transaction to
///      a given (hashed) viewer. An audit export can cite that receipt to show
///      a request was honoured, while the counterparty and the proof remain
///      out of public view.
contract DisclosureLog {
    struct DisclosureReceipt {
        address profile;
        string txReference; // identifier of the confidential transfer disclosed
        bytes32 viewerHash; // hash of the recipient's identity, never the identity itself
        bytes32 disclosureCommitment; // digest of the disclosed payload for later matching
        uint64 filedAt;
        bool exists;
    }

    uint256 internal constant MAX_TX_REFERENCE_LEN = 88;

    IAccountRegistry public immutable registry;

    uint256 public receiptCount;
    mapping(uint256 => DisclosureReceipt) internal _receipts;

    /// @notice Each account's receipt ids in filing order, so exports can read
    ///         them directly instead of reconstructing them from events.
    mapping(address => uint256[]) internal _receiptsByProfile;

    /// @notice Receipt ids grouped by the keccak hash of the transfer reference.
    ///         A single transfer can be disclosed repeatedly (to several viewers
    ///         or on separate occasions), and this lets an auditor fetch all of
    ///         those receipts with one call.
    mapping(bytes32 => uint256[]) internal _receiptsByTransfer;

    event DisclosureFiled(
        uint256 indexed receiptId, address indexed profile, string txReference, uint256 timestamp
    );

    constructor(IAccountRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    /// @notice Logs that the caller produced a disclosure proof for a
    ///         confidential transfer and gave it to a viewer. Nothing from the
    ///         proof is stored on-chain; the receipt captures only that it
    ///         happened and when.
    /// @param txReference Reference string naming the disclosed transfer.
    /// @param viewerHash Hash of the viewer's identity, which keeps an account's
    ///        counterparties from being read off its receipts.
    /// @param disclosureCommitment Digest of the disclosed payload, so the viewer
    ///        can confirm off-chain that their copy matches this receipt.
    function file(string calldata txReference, bytes32 viewerHash, bytes32 disclosureCommitment)
        external
        returns (uint256 receiptId)
    {
        if (!registry.isRegistered(msg.sender)) revert ProfileNotFound();
        uint256 len = bytes(txReference).length;
        if (len == 0 || len > MAX_TX_REFERENCE_LEN) revert InvalidTxReferenceLength();
        // Both hashes are required: without a viewer or a payload digest the
        // receipt would be worthless as evidence to an auditor.
        if (viewerHash == bytes32(0) || disclosureCommitment == bytes32(0)) {
            revert MissingCommitment();
        }

        receiptId = ++receiptCount;
        _receipts[receiptId] = DisclosureReceipt({
            profile: msg.sender,
            txReference: txReference,
            viewerHash: viewerHash,
            disclosureCommitment: disclosureCommitment,
            filedAt: uint64(block.timestamp),
            exists: true
        });
        _receiptsByProfile[msg.sender].push(receiptId);
        _receiptsByTransfer[keccak256(bytes(txReference))].push(receiptId);

        emit DisclosureFiled(receiptId, msg.sender, txReference, block.timestamp);
    }

    function getReceipt(uint256 receiptId) external view returns (DisclosureReceipt memory) {
        return _receipts[receiptId];
    }

    /// @notice Number of receipts filed by `profile`.
    function receiptCountOf(address profile) external view returns (uint256) {
        return _receiptsByProfile[profile].length;
    }

    /// @notice All receipt ids filed by `profile`, in filing order. Call
    ///         {getReceipt} on each to load full details for an export.
    function receiptIdsOf(address profile) external view returns (uint256[] memory) {
        return _receiptsByProfile[profile];
    }

    /// @notice All receipt ids recorded for a transfer reference, in filing
    ///         order and regardless of filer. Returns an empty array if no
    ///         disclosure exists for that transfer.
    function receiptIdsForTransfer(string calldata txReference)
        external
        view
        returns (uint256[] memory)
    {
        return _receiptsByTransfer[keccak256(bytes(txReference))];
    }

    /// @notice Paginated receipt ids for `profile`: up to `limit` entries from
    ///         index `offset`, in filing order. A long disclosure history can
    ///         exceed a single RPC response, so clients keep increasing
    ///         `offset` until a page shorter than `limit` is returned.
    function receiptIdsOf(address profile, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page)
    {
        uint256[] storage all = _receiptsByProfile[profile];
        uint256 total = all.length;
        if (offset >= total) return new uint256[](0);

        // Mirrors the bound in RequestLedger: test `limit` against the
        // remaining count first, so type(uint256).max never overflows.
        uint256 end = limit > total - offset ? total : offset + limit;

        page = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = all[i];
        }
    }
}
