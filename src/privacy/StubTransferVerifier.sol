// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IConfidentialTransferVerifier} from "./IConfidentialTransferVerifier.sol";

/// @title StubTransferVerifier
/// @notice Temporary stand-in for the Groth16 verifier that accepts any input.
///         Its only purpose is to let the confidential token run through its
///         full flow on a local chain or testnet while the circuits are still
///         being built.
///
/// @dev Production deployments must not use this contract. With it active,
///      proofs are not checked at all and the token offers no
///      confidentiality. Call {ConfidentialToken.setVerifier} with the
///      audited verifier before the token holds real funds.
contract StubTransferVerifier is IConfidentialTransferVerifier {
    function verifyTransfer(bytes calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verifyWithdraw(bytes calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }
}
