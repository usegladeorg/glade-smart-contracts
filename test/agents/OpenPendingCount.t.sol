// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {AgentController} from "../../src/agents/AgentController.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

contract AgentOpenPendingCountTest is Test {
    AgentController agents;
    MockERC20 usdg;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address signer = makeAddr("signer");
    address vendor = makeAddr("vendor");

    uint256 agentId;

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

        vm.startPrank(signer);
        for (uint256 i; i < 4; ++i) {
            agents.queueInvoice(agentId, vendor, 1e6, bytes32(0), bytes32(0));
        }
        vm.stopPrank();
    }

    function test_count_tracks_every_way_a_spend_resolves() public {
        assertEq(agents.openPendingCount(agentId), 4);

        vm.prank(gwen);
        agents.approvePending(agentId, 0);
        assertEq(agents.openPendingCount(agentId), 3);

        vm.prank(gwen);
        agents.rejectPending(agentId, 1);
        assertEq(agents.openPendingCount(agentId), 2);

        vm.prank(signer);
        agents.withdrawPending(agentId, 2);
        assertEq(agents.openPendingCount(agentId), 1);

        uint256[] memory ids = agents.openPendingIds(agentId);
        assertEq(ids.length, 1);
        assertEq(ids[0], 3);
    }

    function test_open_ids_skip_resolved_gaps() public {
        vm.startPrank(gwen);
        agents.rejectPending(agentId, 0);
        agents.rejectPending(agentId, 2);
        vm.stopPrank();

        uint256[] memory ids = agents.openPendingIds(agentId);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 3);
    }
}
