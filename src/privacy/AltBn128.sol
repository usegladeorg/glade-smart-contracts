// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title AltBn128
/// @notice Elliptic curve helpers for alt_bn128 (also called BN254), used by
///         Glade's confidential token. Point addition and scalar
///         multiplication go through the 0x06 and 0x07 precompiles, available
///         on Robinhood Chain because it runs the Arbitrum Nitro stack. This
///         lets the chain update encrypted balances without decrypting them.
///
/// @dev The token represents each ElGamal ciphertext as two points on this
///      curve. Summing ciphertexts means summing the matching points, and that
///      homomorphism is what makes private transfers work: one balance is
///      reduced and another increased while the transferred value never
///      leaves encrypted form.
library AltBn128 {
    /// @notice An affine G1 point. The precompiles encode the point at
    ///         infinity as (0, 0), and this library follows that convention.
    struct Point {
        uint256 x;
        uint256 y;
    }

    /// @dev Prime modulus of the base field.
    uint256 internal constant FIELD_MODULUS =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;

    error ECAddFailed();
    error ECMulFailed();

    /// @notice Returns the canonical G1 generator G = (1, 2). A plaintext `m`
    ///         is mapped to the curve as `m * G`.
    function generator() internal pure returns (Point memory) {
        return Point(1, 2);
    }

    /// @notice Returns the point at infinity, the group's neutral element.
    function zero() internal pure returns (Point memory) {
        return Point(0, 0);
    }

    /// @notice Checks that both coordinates of `p` are reduced field elements
    ///         and that `p` satisfies `y^2 = x^3 + 3`. The (0, 0) encoding of
    ///         infinity is rejected on purpose, so callers that want to accept
    ///         it need their own special case.
    /// @param p Point to test.
    /// @return True if `p` is a valid affine curve point.
    function isOnCurve(Point memory p) internal pure returns (bool) {
        if (p.x >= FIELD_MODULUS || p.y >= FIELD_MODULUS) return false;
        uint256 lhs = mulmod(p.y, p.y, FIELD_MODULUS);
        uint256 rhs =
            addmod(mulmod(mulmod(p.x, p.x, FIELD_MODULUS), p.x, FIELD_MODULUS), 3, FIELD_MODULUS);
        return lhs == rhs;
    }

    /// @notice Computes `-p`, the point whose sum with `p` is infinity.
    ///         Encrypted balances are decreased by adding a negated point.
    /// @param p Point to negate.
    function negate(Point memory p) internal pure returns (Point memory) {
        if (p.x == 0 && p.y == 0) return Point(0, 0);
        return Point(p.x, FIELD_MODULUS - (p.y % FIELD_MODULUS));
    }

    /// @notice Returns `a + b`, computed by the ECADD precompile at 0x06.
    /// @param a First summand.
    /// @param b Second summand.
    /// @return r The resulting point.
    function add(Point memory a, Point memory b) internal view returns (Point memory r) {
        uint256[4] memory input = [a.x, a.y, b.x, b.y];
        bool ok;
        assembly {
            ok := staticcall(gas(), 0x06, input, 0x80, r, 0x40)
        }
        if (!ok) revert ECAddFailed();
    }

    /// @notice Returns `s * p`, computed by the ECMUL precompile at 0x07.
    /// @param p Base point.
    /// @param s Scalar multiplier.
    /// @return r The resulting point.
    function mul(Point memory p, uint256 s) internal view returns (Point memory r) {
        uint256[3] memory input = [p.x, p.y, s];
        bool ok;
        assembly {
            ok := staticcall(gas(), 0x07, input, 0x60, r, 0x40)
        }
        if (!ok) revert ECMulFailed();
    }

    /// @notice Maps the integer `m` to the point `m * G`. Deposits add this
    ///         point to a ciphertext balance.
    /// @param m Plaintext value to encode.
    function encode(uint256 m) internal view returns (Point memory) {
        return mul(generator(), m);
    }
}
