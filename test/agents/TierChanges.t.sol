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

contract AgentTierChangeTest is Test {
    ProtocolAuthority protocol;
    AccountRegistry registry;
    AgentController agents;
    MockERC20 usdg;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address mallory = makeAddr("mallory");
    address signer = makeAddr("signer");
    address vendor = makeAddr("vendor");

    uint256 agentId;

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        protocol = new ProtocolAuthority(compliance);
        registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
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
    }

    function test_promoted_agent_can_settle_directly() public {
        vm.expectRevert(TierRequiresApproval.selector);
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, 1e6, bytes32(0));

        vm.prank(gwen);
        agents.setAutonomyTier(agentId, AgentController.AutonomyTier.SemiAutonomous);

        vm.prank(signer);
        agents.payInvoice(agentId, vendor, 1e6, bytes32(0));
        assertEq(usdg.balanceOf(vendor), 1e6);
    }

    function test_tier_change_emits_previous_and_new_tier() public {
        vm.expectEmit(true, false, false, true);
        emit AgentController.AutonomyTierChanged(
            agentId,
            AgentController.AutonomyTier.Supervised,
            AgentController.AutonomyTier.FullyAutonomous,
            block.timestamp
        );
        vm.prank(gwen);
        agents.setAutonomyTier(agentId, AgentController.AutonomyTier.FullyAutonomous);

        assertEq(
            uint256(agents.getAgent(agentId).autonomyTier),
            uint256(AgentController.AutonomyTier.FullyAutonomous)
        );
    }

    function test_only_owner_can_change_tier() public {
        vm.expectRevert(UnauthorizedAgentOwner.selector);
        vm.prank(signer);
        agents.setAutonomyTier(agentId, AgentController.AutonomyTier.FullyAutonomous);

        vm.expectRevert(UnauthorizedAgentOwner.selector);
        vm.prank(mallory);
        agents.setAutonomyTier(agentId, AgentController.AutonomyTier.FullyAutonomous);
    }

    function test_rejects_same_tier() public {
        vm.expectRevert(AgentController.SameAutonomyTier.selector);
        vm.prank(gwen);
        agents.setAutonomyTier(agentId, AgentController.AutonomyTier.Supervised);
    }

    function test_revoked_agent_tier_is_frozen() public {
        vm.startPrank(gwen);
        agents.revokeAgent(agentId);
        vm.expectRevert(AgentAlreadyRevoked.selector);
        agents.setAutonomyTier(agentId, AgentController.AutonomyTier.FullyAutonomous);
        vm.stopPrank();
    }
}
