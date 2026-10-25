// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {RequestLedger} from "../../src/payments/RequestLedger.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

contract RequestBatchLookupTest is Test {
    RequestLedger requests;
    MockERC20 usdg;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        ProtocolAuthority protocol = new ProtocolAuthority(compliance);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);

        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.startPrank(gwen);
        requests.create(gwen, address(usdg), false, 10e6, bytes32(0), bytes32(0), expiry);
        requests.create(gwen, address(usdg), false, 20e6, bytes32(0), bytes32(0), expiry);
        requests.create(gwen, address(usdg), false, 30e6, bytes32(0), bytes32(0), expiry);
        vm.stopPrank();
    }

    function test_returns_records_in_requested_order() public view {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 3;
        ids[1] = 1;

        RequestLedger.Request[] memory got = requests.getRequests(ids);
        assertEq(got.length, 2);
        assertEq(got[0].amount, 30e6);
        assertEq(got[1].amount, 10e6);
    }

    function test_unknown_ids_come_back_empty() public view {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 99;

        RequestLedger.Request[] memory got = requests.getRequests(ids);
        assertTrue(got[0].exists);
        assertFalse(got[1].exists);
        assertEq(got[1].requester, address(0));
    }

    function test_works_with_a_page_of_ids() public view {
        RequestLedger.Request[] memory got = requests.getRequests(requests.requestIdsOf(gwen, 1, 2));
        assertEq(got.length, 2);
        assertEq(got[0].amount, 20e6);
        assertEq(got[1].amount, 30e6);
    }

    function test_empty_input_returns_empty_array() public view {
        assertEq(requests.getRequests(new uint256[](0)).length, 0);
    }
}
