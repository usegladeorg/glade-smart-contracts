// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IConfidentialTransferVerifier
/// @notice Interface the confidential token calls to validate proofs. The
///         production implementation will be a standalone Groth16 verifier
///         generated from Glade's Circom or Noir circuits. Keeping it in its
///         own contract means the proof system can change while every stored
///         balance stays where it is.
///
/// @dev `publicSignals` holds the circuit's public inputs as one flat array:
///      the ElGamal public keys of the parties, the relevant ciphertexts, and
///      the encrypted deltas. Its layout depends on the circuit, so the token
///      passes it along unchanged and leaves interpretation to the verifier.
interface IConfidentialTransferVerifier {
    /// @notice Validates a confidential transfer proof.
    /// @dev Must return true only if the sender and recipient deltas encrypt
    ///      the same non-negative value and the sender's balance remains
    ///      non-negative after the debit.
    function verifyTransfer(bytes calldata proof, uint256[] calldata publicSignals)
        external
        view
        returns (bool);

    /// @notice Validates a withdrawal proof.
    /// @dev Must return true only if the caller's encrypted balance is at
    ///      least the amount being withdrawn.
    function verifyWithdraw(bytes calldata proof, uint256[] calldata publicSignals)
        external
        view
        returns (bool);
}
