// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";

contract HandleBatchResolveTest is Test {
    AccountRegistry registry;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");

    function setUp() public {
        ProtocolAuthority protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", AccountRegistry.AccountKind.Business);
    }

    function test_resolves_in_requested_order() public view {
        string[] memory handles = new string[](3);
        handles[0] = "felix";
        handles[1] = "nobody";
        handles[2] = "gwen";

        address[] memory owners = registry.resolveHandles(handles);
        assertEq(owners.length, 3);
        assertEq(owners[0], felix);
        assertEq(owners[1], address(0));
        assertEq(owners[2], gwen);
    }

    function test_follows_handle_changes() public {
        vm.prank(gwen);
        registry.changeHandle("gwendolyn");

        string[] memory handles = new string[](2);
        handles[0] = "gwen";
        handles[1] = "gwendolyn";

        address[] memory owners = registry.resolveHandles(handles);
        assertEq(owners[0], address(0));
        assertEq(owners[1], gwen);
    }

    function test_empty_input_returns_empty_array() public view {
        assertEq(registry.resolveHandles(new string[](0)).length, 0);
    }
}
