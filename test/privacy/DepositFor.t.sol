// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AltBn128} from "../../src/privacy/AltBn128.sol";
import {ConfidentialToken} from "../../src/privacy/ConfidentialToken.sol";
import {StubTransferVerifier} from "../../src/privacy/StubTransferVerifier.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import "../../src/utils/ProtocolErrors.sol";

contract ConfidentialDepositForTest is Test {
    ConfidentialToken confidential;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address felix = makeAddr("felix");
    address gwen = makeAddr("gwen");
    address theo = makeAddr("theo");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        confidential =
            new ConfidentialToken(IERC20(address(usdg)), new StubTransferVerifier(), admin);

        AltBn128.Point memory pk = AltBn128.encode(7);
        vm.prank(gwen);
        confidential.register(pk.x, pk.y);

        usdg.mint(felix, 100e6);
        vm.prank(felix);
        usdg.approve(address(confidential), type(uint256).max);
    }

    function test_credits_the_recipient_not_the_payer() public {
        vm.expectEmit(true, false, false, true);
        emit ConfidentialToken.Deposited(gwen, 5e6);
        vm.prank(felix);
        confidential.depositFor(gwen, 5e6);

        AltBn128.Point memory expected = AltBn128.encode(5e6);
        ConfidentialToken.Ciphertext memory bal = confidential.encryptedBalanceOf(gwen);
        assertEq(bal.c2.x, expected.x);
        assertEq(bal.c2.y, expected.y);

        assertEq(usdg.balanceOf(felix), 95e6);
        assertEq(confidential.totalWrapped(), 5e6);
        assertTrue(confidential.isFullyBacked());
    }

    function test_payer_does_not_need_to_be_registered() public {
        assertFalse(confidential.registered(felix));
        vm.prank(felix);
        confidential.depositFor(gwen, 1e6);
        assertEq(confidential.totalWrapped(), 1e6);
    }

    function test_recipient_must_be_registered() public {
        vm.expectRevert(AccountNotRegistered.selector);
        vm.prank(felix);
        confidential.depositFor(theo, 1e6);
    }

    function test_respects_the_pause() public {
        vm.prank(admin);
        confidential.setPaused(true);

        vm.expectRevert(ConfidentialToken.TokenPaused.selector);
        vm.prank(felix);
        confidential.depositFor(gwen, 1e6);
    }
}
