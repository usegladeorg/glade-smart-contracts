// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";

contract ProtocolPauseToggleTest is Test {
    ProtocolAuthority protocol;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");

    function setUp() public {
        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);
    }

    function test_unpausing_while_unpaused_reverts() public {
        vm.expectRevert(ProtocolAuthority.PauseUnchanged.selector);
        vm.prank(admin);
        protocol.setPause(false);
    }

    function test_pausing_twice_reverts() public {
        vm.startPrank(admin);
        protocol.setPause(true);
        vm.expectRevert(ProtocolAuthority.PauseUnchanged.selector);
        protocol.setPause(true);
        vm.stopPrank();
        assertTrue(protocol.paused());
    }

    function test_pause_round_trip_still_works() public {
        vm.startPrank(admin);
        protocol.setPause(true);
        protocol.setPause(false);
        vm.stopPrank();
        assertFalse(protocol.paused());
    }
}
