// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {AgentController} from "../../src/agents/AgentController.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import "../../src/utils/ProtocolErrors.sol";

contract AgentPendingExpiryTest is Test {
    AgentController agents;
    MockERC20 usdg;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address signer = makeAddr("signer");
    address vendor = makeAddr("vendor");

    uint256 agentId;
    uint256 pendingId;
    uint256 queuedAt;

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        ProtocolAuthority protocol = new ProtocolAuthority(compliance);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        usdg.mint(gwen, 1_000e6);

        address[] memory none = new address[](0);
        vm.startPrank(gwen);
        agentId = agents.createAgent(
            signer,
            "coding-assistant",
            AgentController.AutonomyTier.Supervised,
            address(usdg),
            10e6,
            50e6,
            5e6,
            none,
            false
        );
        usdg.approve(address(agents), type(uint256).max);
        agents.fundAgent(agentId, 100e6);
        vm.stopPrank();

        queuedAt = block.timestamp;
        vm.prank(signer);
        pendingId = agents.queueInvoice(agentId, vendor, 1e6, bytes32(0), bytes32(0));
    }

    function test_approves_just_before_expiry() public {
        vm.warp(queuedAt + agents.PENDING_TTL() - 1);
        vm.prank(gwen);
        agents.approvePending(agentId, pendingId);
        assertEq(usdg.balanceOf(vendor), 1e6);
    }

    function test_rejects_approval_once_expired() public {
        vm.warp(queuedAt + agents.PENDING_TTL());
        vm.expectRevert(PendingApprovalExpired.selector);
        vm.prank(gwen);
        agents.approvePending(agentId, pendingId);
    }

    function test_expired_entries_can_still_be_cleared() public {
        vm.warp(queuedAt + agents.PENDING_TTL() + 1);
        vm.prank(gwen);
        agents.rejectPending(agentId, pendingId);
        assertEq(agents.openPendingCount(agentId), 0);
    }
}
