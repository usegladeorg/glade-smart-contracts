// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";

contract ComplianceAuthorityNoopTest is Test {
    ProtocolAuthority protocol;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address persona = makeAddr("persona");

    function setUp() public {
        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);
    }

    function test_setting_the_current_provider_reverts() public {
        vm.expectRevert(ProtocolAuthority.SameComplianceAuthority.selector);
        vm.prank(admin);
        protocol.setComplianceAuthority(compliance);
    }

    function test_switching_provider_still_works() public {
        vm.prank(admin);
        protocol.setComplianceAuthority(persona);
        assertEq(protocol.complianceAuthority(), persona);
    }

    function test_switching_back_is_allowed() public {
        vm.startPrank(admin);
        protocol.setComplianceAuthority(persona);
        protocol.setComplianceAuthority(compliance);
        vm.stopPrank();
        assertEq(protocol.complianceAuthority(), compliance);
    }
}
