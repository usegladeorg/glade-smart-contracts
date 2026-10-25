// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeSchedule} from "../../src/payments/FeeSchedule.sol";

contract FeeScheduleNoopTest is Test {
    FeeSchedule fees;

    address admin = makeAddr("admin");

    function setUp() public {
        fees = new FeeSchedule(admin);
    }

    function test_repeating_the_live_schedule_reverts() public {
        vm.expectRevert(FeeSchedule.ScheduleUnchanged.selector);
        vm.prank(admin);
        fees.setSchedule(10, 5_000_000);
    }

    function test_changing_only_the_rate_is_allowed() public {
        vm.prank(admin);
        fees.setSchedule(20, 5_000_000);
        assertEq(fees.baseFeeBps(), 20);
    }

    function test_changing_only_the_cap_is_allowed() public {
        vm.prank(admin);
        fees.setSchedule(10, 0);
        assertEq(fees.feeCap(), 0);
    }
}
