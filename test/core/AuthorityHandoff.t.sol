// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {FeeSchedule} from "../../src/payments/FeeSchedule.sol";
import "../../src/utils/ProtocolErrors.sol";

contract ProtocolAuthorityTransferTest is Test {
    ProtocolAuthority protocol;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address nextAdmin = makeAddr("nextAdmin");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);
    }

    function test_only_authority_can_begin_transfer() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(stranger);
        protocol.beginAuthorityTransfer(nextAdmin);
    }

    function test_two_step_handoff() public {
        vm.prank(admin);
        protocol.beginAuthorityTransfer(nextAdmin);

        // Until acceptance the admin keeps the role and the nominee only sits in the pending slot.
        assertEq(protocol.authority(), admin);
        assertEq(protocol.pendingAuthority(), nextAdmin);

        // Accepting is reserved for the address that was nominated.
        vm.expectRevert(ProtocolAuthority.NotPendingAuthority.selector);
        vm.prank(stranger);
        protocol.acceptAuthority();

        vm.prank(nextAdmin);
        protocol.acceptAuthority();

        assertEq(protocol.authority(), nextAdmin);
        assertEq(protocol.pendingAuthority(), address(0));
    }

    function test_new_authority_can_pause_old_cannot() public {
        vm.prank(admin);
        protocol.beginAuthorityTransfer(nextAdmin);
        vm.prank(nextAdmin);
        protocol.acceptAuthority();

        vm.expectRevert(Unauthorized.selector);
        vm.prank(admin);
        protocol.setPause(true);

        vm.prank(nextAdmin);
        protocol.setPause(true);
        assertTrue(protocol.paused());
    }

    function test_pending_can_be_cancelled() public {
        vm.startPrank(admin);
        protocol.beginAuthorityTransfer(nextAdmin);
        protocol.beginAuthorityTransfer(address(0));
        vm.stopPrank();

        assertEq(protocol.pendingAuthority(), address(0));
        vm.expectRevert(ProtocolAuthority.NotPendingAuthority.selector);
        vm.prank(nextAdmin);
        protocol.acceptAuthority();
    }

    function test_direct_update_clears_pending() public {
        vm.startPrank(admin);
        protocol.beginAuthorityTransfer(nextAdmin);
        // An updateConfig call overwrites the authority directly and wipes the pending nominee.
        protocol.updateConfig(admin, compliance);
        vm.stopPrank();

        assertEq(protocol.pendingAuthority(), address(0));
        vm.expectRevert(ProtocolAuthority.NotPendingAuthority.selector);
        vm.prank(nextAdmin);
        protocol.acceptAuthority();
    }

    function test_compliance_authority_rotates_on_its_own() public {
        address vendor = makeAddr("vendor");

        vm.expectRevert(Unauthorized.selector);
        vm.prank(stranger);
        protocol.setComplianceAuthority(vendor);

        vm.expectRevert(ZeroAddress.selector);
        vm.prank(admin);
        protocol.setComplianceAuthority(address(0));

        // Rotating compliance mid handoff must not disturb the pending nomination.
        vm.prank(admin);
        protocol.beginAuthorityTransfer(nextAdmin);
        vm.prank(admin);
        protocol.setComplianceAuthority(vendor);

        assertEq(protocol.complianceAuthority(), vendor);
        assertEq(protocol.authority(), admin);
        assertEq(protocol.pendingAuthority(), nextAdmin);
    }

    // Treasury and schedule are set together or cleared together; a half config reverts.
    function test_fee_routing_is_all_or_nothing() public {
        address treasury = makeAddr("treasury");
        address schedule = address(new FeeSchedule(admin));

        vm.expectRevert(InvalidFeeConfig.selector);
        vm.prank(admin);
        protocol.setFeeConfig(treasury, address(0));

        vm.expectRevert(InvalidFeeConfig.selector);
        vm.prank(admin);
        protocol.setFeeConfig(address(0), schedule);

        vm.prank(admin);
        protocol.setFeeConfig(treasury, schedule);
        assertEq(protocol.treasury(), treasury);
        assertEq(protocol.feeSchedule(), schedule);

        vm.prank(admin);
        protocol.setFeeConfig(address(0), address(0));
        assertEq(protocol.treasury(), address(0));
        assertEq(protocol.feeSchedule(), address(0));
    }

    function test_fee_schedule_must_be_a_contract() public {
        address treasury = makeAddr("treasury");

        vm.expectRevert(InvalidFeeConfig.selector);
        vm.prank(admin);
        protocol.setFeeConfig(treasury, makeAddr("wallet"));

        assertEq(protocol.feeSchedule(), address(0));
    }
}
