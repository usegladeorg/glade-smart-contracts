// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {AgentController} from "../../src/agents/AgentController.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

contract AgentPendingBatchLookupTest is Test {
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

        address[] memory none = new address[](0);
        vm.prank(gwen);
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

        vm.startPrank(signer);
        agents.queueInvoice(agentId, vendor, 1e6, keccak256("inv-1"), bytes32(0));
        agents.queueInvoice(agentId, vendor, 2e6, keccak256("inv-2"), bytes32(0));
        agents.queueInvoice(agentId, vendor, 3e6, keccak256("inv-3"), bytes32(0));
        vm.stopPrank();
    }

    function test_loads_every_open_entry() public {
        vm.prank(gwen);
        agents.rejectPending(agentId, 1);

        AgentController.PendingApproval[] memory got =
            agents.getPendingApprovals(agentId, agents.openPendingIds(agentId));
        assertEq(got.length, 2);
        assertEq(got[0].amount, 1e6);
        assertEq(got[0].invoiceId, keccak256("inv-1"));
        assertEq(got[1].amount, 3e6);
        assertEq(got[1].invoiceId, keccak256("inv-3"));
    }

    function test_resolved_and_unknown_ids_come_back_empty() public {
        vm.prank(gwen);
        agents.rejectPending(agentId, 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 99;

        AgentController.PendingApproval[] memory got = agents.getPendingApprovals(agentId, ids);
        assertFalse(got[0].exists);
        assertFalse(got[1].exists);
    }
}
