// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeSchedule} from "../../src/payments/FeeSchedule.sol";
import "../../src/utils/ProtocolErrors.sol";

/// @notice Two-step handover of the FeeSchedule authority role.
contract FeeScheduleAuthorityTest is Test {
    FeeSchedule fees;

    address admin = makeAddr("admin");
    address multisig = makeAddr("multisig");
    address mallory = makeAddr("mallory");

    function setUp() public {
        fees = new FeeSchedule(admin);
    }

    function test_handoff_completes_only_after_acceptance() public {
        vm.prank(admin);
        fees.beginAuthorityTransfer(multisig);

        // Until the nominee accepts, the current authority keeps control and
        // can still change the schedule.
        assertEq(fees.authority(), admin);
        assertEq(fees.pendingAuthority(), multisig);
        vm.prank(admin);
        fees.setSchedule(20, 5_000_000);

        vm.prank(multisig);
        fees.acceptAuthority();
        assertEq(fees.authority(), multisig);
        assertEq(fees.pendingAuthority(), address(0));

        // After acceptance the new authority can set the schedule and the old
        // one is locked out.
        vm.prank(multisig);
        fees.setSchedule(10, 5_000_000);
        vm.expectRevert(Unauthorized.selector);
        vm.prank(admin);
        fees.setSchedule(30, 5_000_000);
    }

    function test_only_the_nominee_can_accept() public {
        vm.prank(admin);
        fees.beginAuthorityTransfer(multisig);

        vm.expectRevert(FeeSchedule.NotPendingAuthority.selector);
        vm.prank(mallory);
        fees.acceptAuthority();
    }

    function test_only_authority_can_nominate() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(mallory);
        fees.beginAuthorityTransfer(mallory);
    }

    function test_zero_nomination_cancels_a_pending_handoff() public {
        vm.startPrank(admin);
        fees.beginAuthorityTransfer(multisig);
        fees.beginAuthorityTransfer(address(0));
        vm.stopPrank();

        vm.expectRevert(FeeSchedule.NotPendingAuthority.selector);
        vm.prank(multisig);
        fees.acceptAuthority();
        assertEq(fees.authority(), admin);
    }
}
