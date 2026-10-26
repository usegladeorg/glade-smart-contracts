// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {RequestLedger} from "../../src/payments/RequestLedger.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import "../../src/utils/ProtocolErrors.sol";

contract RequestLifetimeTest is Test {
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
    }

    function _create(uint64 expiresAt) internal returns (uint256) {
        vm.prank(gwen);
        return requests.create(gwen, address(usdg), false, 25e6, bytes32(0), bytes32(0), expiresAt);
    }

    function test_accepts_expiry_at_the_limit() public {
        uint64 limit = uint64(block.timestamp) + requests.MAX_REQUEST_LIFETIME();
        uint256 id = _create(limit);
        assertEq(requests.getRequest(id).expiresAt, limit);
    }

    function test_rejects_expiry_past_the_limit() public {
        uint64 tooFar = uint64(block.timestamp) + requests.MAX_REQUEST_LIFETIME() + 1;
        vm.expectRevert(InvalidExpiry.selector);
        vm.prank(gwen);
        requests.create(gwen, address(usdg), false, 25e6, bytes32(0), bytes32(0), tooFar);
    }

    function test_extension_is_bounded_from_now() public {
        uint256 id = _create(uint64(block.timestamp + 30 days));

        uint64 tooFar = uint64(block.timestamp) + requests.MAX_REQUEST_LIFETIME() + 1;
        vm.expectRevert(InvalidExpiry.selector);
        vm.prank(gwen);
        requests.extendExpiry(id, tooFar);

        // Later on, the same target falls inside the window and is accepted.
        vm.warp(block.timestamp + 20 days);
        vm.prank(gwen);
        requests.extendExpiry(id, tooFar);
        assertEq(requests.getRequest(id).expiresAt, tooFar);
    }
}
