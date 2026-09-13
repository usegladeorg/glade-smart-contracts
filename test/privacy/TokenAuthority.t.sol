// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConfidentialToken} from "../../src/privacy/ConfidentialToken.sol";
import {StubTransferVerifier} from "../../src/privacy/StubTransferVerifier.sol";
import {IConfidentialTransferVerifier} from "../../src/privacy/IConfidentialTransferVerifier.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import "../../src/utils/ProtocolErrors.sol";

contract ConfidentialTokenAuthorityTest is Test {
    ConfidentialToken confidential;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address multisig = makeAddr("multisig");
    address mallory = makeAddr("mallory");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        confidential =
            new ConfidentialToken(IERC20(address(usdg)), new StubTransferVerifier(), admin);
    }

    function test_handoff_completes_only_after_acceptance() public {
        vm.prank(admin);
        confidential.beginAuthorityTransfer(multisig);

        // While the nomination is pending, the current admin keeps full control.
        assertEq(confidential.authority(), admin);
        assertEq(confidential.pendingAuthority(), multisig);
        vm.prank(admin);
        confidential.setPaused(true);

        vm.prank(multisig);
        confidential.acceptAuthority();
        assertEq(confidential.authority(), multisig);
        assertEq(confidential.pendingAuthority(), address(0));

        // After acceptance the multisig can act and the former admin is rejected.
        vm.prank(multisig);
        confidential.setPaused(false);
        vm.expectRevert(Unauthorized.selector);
        vm.prank(admin);
        confidential.setPaused(true);
    }

    function test_only_the_nominee_can_accept() public {
        vm.prank(admin);
        confidential.beginAuthorityTransfer(multisig);

        vm.expectRevert(ConfidentialToken.NotPendingAuthority.selector);
        vm.prank(mallory);
        confidential.acceptAuthority();
    }

    function test_only_authority_can_nominate() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(mallory);
        confidential.beginAuthorityTransfer(mallory);
    }

    // Nominating address(0) withdraws an earlier nomination.
    function test_zero_nomination_cancels_a_pending_handoff() public {
        vm.startPrank(admin);
        confidential.beginAuthorityTransfer(multisig);
        confidential.beginAuthorityTransfer(address(0));
        vm.stopPrank();

        vm.expectRevert(ConfidentialToken.NotPendingAuthority.selector);
        vm.prank(multisig);
        confidential.acceptAuthority();
        assertEq(confidential.authority(), admin);
    }

    event VerifierUpdated(address indexed previousVerifier, address indexed verifier);

    // The VerifierUpdated event must carry the old and new verifier addresses.
    function test_verifier_rotation_names_both_ends() public {
        address before = address(confidential.verifier());
        StubTransferVerifier next = new StubTransferVerifier();

        vm.expectEmit(true, true, false, false, address(confidential));
        emit VerifierUpdated(before, address(next));
        vm.prank(admin);
        confidential.setVerifier(IConfidentialTransferVerifier(address(next)));

        assertEq(address(confidential.verifier()), address(next));
    }

    function test_verifier_rotation_to_itself_reverts() public {
        IConfidentialTransferVerifier current = confidential.verifier();
        vm.expectRevert(ConfidentialToken.SameVerifier.selector);
        vm.prank(admin);
        confidential.setVerifier(current);
    }
}
