// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AltBn128} from "../../src/privacy/AltBn128.sol";
import {ConfidentialToken} from "../../src/privacy/ConfidentialToken.sol";
import {StubTransferVerifier} from "../../src/privacy/StubTransferVerifier.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import "../../src/utils/ProtocolErrors.sol";

contract ConfidentialTokenRegisterTest is Test {
    ConfidentialToken confidential;

    address admin = makeAddr("admin");
    address felix = makeAddr("felix");

    function setUp() public {
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        confidential =
            new ConfidentialToken(IERC20(address(usdg)), new StubTransferVerifier(), admin);
    }

    function test_accepts_a_real_curve_point() public {
        // (1, 2) is the alt_bn128 generator, the simplest solution of y^2 = x^3 + 3.
        vm.prank(felix);
        confidential.register(1, 2);
        assertTrue(confidential.registered(felix));

        (uint256 x, uint256 y) = confidential.publicKeyOf(felix);
        assertEq(x, 1);
        assertEq(y, 2);
    }

    function test_accepts_a_derived_public_key() public {
        // Same derivation a client performs: multiply G by a private scalar.
        AltBn128.Point memory p = AltBn128.encode(0xdeadbeef);
        vm.prank(felix);
        confidential.register(p.x, p.y);
        assertTrue(confidential.registered(felix));
    }

    function test_rejects_a_point_off_the_curve() public {
        // (7, 11) is not on the curve. Accepting it would strand any funds sent to
        // the account, because no private key could ever decrypt them.
        vm.expectRevert(InvalidPublicKey.selector);
        vm.prank(felix);
        confidential.register(7, 11);
    }

    function test_rejects_the_identity() public {
        vm.expectRevert(InvalidPublicKey.selector);
        vm.prank(felix);
        confidential.register(0, 0);
    }

    function test_rejects_coordinates_outside_the_field() public {
        // Adding the modulus to y keeps the equation true mod p but leaves the
        // coordinate unreduced, which registration must reject.
        uint256 p = AltBn128.FIELD_MODULUS;
        vm.expectRevert(InvalidPublicKey.selector);
        vm.prank(felix);
        confidential.register(1, 2 + p);
    }

    function test_valid_key_still_registers_only_once() public {
        vm.startPrank(felix);
        confidential.register(1, 2);
        vm.expectRevert(AccountAlreadyRegistered.selector);
        confidential.register(1, 2);
        vm.stopPrank();
    }
}
