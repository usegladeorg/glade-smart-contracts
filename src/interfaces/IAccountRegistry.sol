// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IAccountRegistry
/// @notice Minimal view of the Glade account registry used by the agent,
///         payment request, and disclosure contracts. They call it to confirm
///         that a caller has an account before allowing that caller to create
///         records tied to it.
interface IAccountRegistry {
    enum KycTier {
        Unverified,
        Basic,
        Enhanced
    }

    function isRegistered(address owner) external view returns (bool);
    function handleOf(address owner) external view returns (string memory);
    function kycTierOf(address owner) external view returns (KycTier);
}
