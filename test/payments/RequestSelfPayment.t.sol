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

contract RequestSelfPaymentTest is Test {
    RequestLedger requests;
    MockERC20 usdg;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address treasury = makeAddr("treasury");
    address felix = makeAddr("felix");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        ProtocolAuthority protocol = new ProtocolAuthority(compliance);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Business);

        usdg.mint(gwen, 100e6);
        usdg.mint(treasury, 100e6);
        usdg.mint(felix, 100e6);
    }

    function _create(address receiver) internal returns (uint256) {
        vm.prank(gwen);
        return requests.create(
            receiver,
            address(usdg),
            false,
            25e6,
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 days)
        );
    }

    function test_receiver_cannot_pay_their_own_request() public {
        uint256 id = _create(treasury);

        vm.startPrank(treasury);
        usdg.approve(address(requests), type(uint256).max);
        vm.expectRevert(SelfPayment.selector);
        requests.fulfill(id, 25e6, bytes32(0));
        vm.stopPrank();

        assertTrue(requests.isFulfillable(id));
    }

    function test_requester_can_still_pay_when_receiver_differs() public {
        uint256 id = _create(treasury);

        vm.startPrank(gwen);
        usdg.approve(address(requests), type(uint256).max);
        requests.fulfill(id, 25e6, bytes32(0));
        vm.stopPrank();

        assertEq(usdg.balanceOf(treasury), 125e6);
    }

    function test_other_payers_are_unaffected() public {
        uint256 id = _create(gwen);

        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        requests.fulfill(id, 25e6, bytes32(0));
        vm.stopPrank();

        assertEq(usdg.balanceOf(gwen), 125e6);
    }
}
