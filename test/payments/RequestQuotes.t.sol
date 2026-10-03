// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {RequestLedger} from "../../src/payments/RequestLedger.sol";
import {FeeSchedule} from "../../src/payments/FeeSchedule.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

contract RequestLedgerQuoteTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    RequestLedger requests;
    FeeSchedule fees;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address treasury = makeAddr("treasury");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);

        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        fees = new FeeSchedule(admin);

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
    }

    function test_quote_is_the_bare_amount_while_fees_are_off() public view {
        (uint256 fee, uint256 total) = requests.quotePayment(felix, 25e6);
        assertEq(fee, 0);
        assertEq(total, 25e6);
    }

    function test_quote_adds_the_scheduled_fee() public {
        vm.prank(admin);
        protocol.setFeeConfig(treasury, address(fees));

        // 10 bps on 25 USDG comes to 0.025 USDG.
        (uint256 fee, uint256 total) = requests.quotePayment(felix, 25e6);
        assertEq(fee, 25_000);
        assertEq(total, 25e6 + 25_000);

        // For a very large amount the fee is capped at 5 USDG.
        (fee, total) = requests.quotePayment(felix, 1_000_000e6);
        assertEq(fee, 5e6);
        assertEq(total, 1_000_000e6 + 5e6);
    }

    /// Funding and approving exactly the quoted total must leave the payer
    /// with zero balance and zero remaining allowance after fulfill.
    function test_quote_covers_exactly_what_fulfill_pulls() public {
        vm.prank(admin);
        protocol.setFeeConfig(treasury, address(fees));

        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            25e6,
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 hours)
        );

        (, uint256 total) = requests.quotePayment(felix, 25e6);
        usdg.mint(felix, total);

        vm.startPrank(felix);
        usdg.approve(address(requests), total);
        requests.fulfill(id, 25e6, bytes32(0));
        vm.stopPrank();

        assertEq(usdg.balanceOf(felix), 0);
        assertEq(usdg.allowance(felix, address(requests)), 0);
    }
}
