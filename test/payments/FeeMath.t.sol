// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {AgentController} from "../../src/agents/AgentController.sol";
import {RequestLedger} from "../../src/payments/RequestLedger.sol";
import {FeeSchedule} from "../../src/payments/FeeSchedule.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @notice End to end coverage of fees: how FeeSchedule computes a quote, and
///         how agent payments and payment requests each send the fee to the
///         treasury.
contract FeeModelTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    AgentController agents;
    RequestLedger requests;
    FeeSchedule fees;
    MockERC20 usdg; // settlement token, 6 decimals

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address treasury = makeAddr("treasury");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");
    address vendor = makeAddr("vendor");
    address signer = makeAddr("signer");

    function usd(uint256 d) internal pure returns (uint256) {
        return d * 1e6;
    }

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);

        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        fees = new FeeSchedule(admin);

        vm.prank(admin);
        protocol.setFeeConfig(treasury, address(fees));

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", AccountRegistry.AccountKind.Personal);

        usdg.mint(gwen, usd(1_000_000));
        usdg.mint(felix, usd(1_000_000));
    }

    // Quote arithmetic

    function test_base_fee() public view {
        // 10 bps applied to 1,000 USDG yields 1 USDG.
        (uint256 fee, uint256 bps) = fees.quoteFee(gwen, usd(1_000));
        assertEq(fee, usd(1));
        assertEq(bps, 10);
    }

    function test_fee_capped_at_five_usdg() public view {
        // The uncapped fee would be 100 USDG; the cap brings it down to 5 USDG.
        (uint256 fee, uint256 bps) = fees.quoteFee(gwen, usd(100_000));
        assertEq(fee, usd(5));
        assertEq(bps, 0); // effective rate is under 1 bp, so it truncates to 0
    }

    function test_every_payer_pays_the_same_rate() public view {
        (uint256 gwenFee,) = fees.quoteFee(gwen, usd(2_500));
        (uint256 felixFee,) = fees.quoteFee(felix, usd(2_500));
        assertEq(gwenFee, felixFee);
    }

    function test_zero_amount_quotes_nothing() public view {
        (uint256 fee, uint256 bps) = fees.quoteFee(gwen, 0);
        assertEq(fee, 0);
        assertEq(bps, 0);
    }

    // Where fees go when payments settle

    function _fundedAgent() internal returns (uint256 agentId) {
        address[] memory none = new address[](0);
        vm.prank(gwen);
        agentId = agents.createAgent(
            signer,
            "bot",
            AgentController.AutonomyTier.SemiAutonomous,
            address(usdg),
            usd(2_000),
            usd(10_000),
            usd(2_000),
            none,
            false
        );
        vm.startPrank(gwen);
        usdg.approve(address(agents), type(uint256).max);
        agents.fundAgent(agentId, usd(5_000));
        vm.stopPrank();
    }

    function test_agent_pay_charges_fee_to_treasury() public {
        uint256 agentId = _fundedAgent();

        // The vault pays both the 1,000 USDG invoice and its 1 USDG fee.
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(1_000), bytes32("inv"));

        uint256 expectedFee = usd(1);
        assertEq(usdg.balanceOf(vendor), usd(1_000)); // vendor receives the full amount
        assertEq(usdg.balanceOf(treasury), expectedFee); // treasury collects the fee
        assertEq(agents.vaultBalance(agentId), usd(5_000) - usd(1_000) - expectedFee);
    }

    function test_agent_pay_no_fee_when_unconfigured() public {
        // With the treasury and schedule cleared, no fee is taken at all.
        vm.prank(admin);
        protocol.setFeeConfig(address(0), address(0));

        uint256 agentId = _fundedAgent();
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(1_000), bytes32("inv"));

        assertEq(usdg.balanceOf(vendor), usd(1_000));
        assertEq(usdg.balanceOf(treasury), 0);
        assertEq(agents.vaultBalance(agentId), usd(5_000) - usd(1_000));
    }

    function test_payment_request_charges_fee_on_top() public {
        // felix settles gwen's 500 USDG request and pays the fee in addition.
        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            usd(500),
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 days)
        );

        uint256 gwenBefore = usdg.balanceOf(gwen);
        uint256 felixBefore = usdg.balanceOf(felix);

        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        requests.fulfill(id, usd(500), bytes32(0));
        vm.stopPrank();

        uint256 fee = usd(500) * 10 / 10_000; // 10 bps of 500 USDG, i.e. 0.5 USDG
        assertEq(usdg.balanceOf(gwen), gwenBefore + usd(500)); // requester gets exactly 500
        assertEq(usdg.balanceOf(treasury), fee);
        assertEq(usdg.balanceOf(felix), felixBefore - usd(500) - fee); // fee comes from the payer
    }

    function test_only_authority_tunes_schedule() public {
        vm.expectRevert();
        vm.prank(gwen);
        fees.setSchedule(20, usd(10));

        vm.prank(admin);
        fees.setSchedule(20, usd(10));
        assertEq(fees.baseFeeBps(), 20);
        assertEq(fees.feeCap(), usd(10));
    }
}
