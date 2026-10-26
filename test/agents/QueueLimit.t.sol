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

contract AgentQueueLimitTest is Test {
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
    }

    function _fillQueue() internal {
        uint256 max = agents.MAX_OPEN_PENDING();
        vm.startPrank(signer);
        for (uint256 i; i < max; ++i) {
            agents.queueInvoice(agentId, vendor, 1e6, bytes32(0), bytes32(0));
        }
        vm.stopPrank();
    }

    function test_queue_stops_at_the_limit() public {
        _fillQueue();

        vm.expectRevert(TooManyPendingApprovals.selector);
        vm.prank(signer);
        agents.queueInvoice(agentId, vendor, 1e6, bytes32(0), bytes32(0));
    }

    function test_resolving_an_entry_frees_a_slot() public {
        _fillQueue();

        vm.prank(gwen);
        agents.rejectPending(agentId, 0);

        vm.prank(signer);
        agents.queueInvoice(agentId, vendor, 1e6, bytes32(0), bytes32(0));
        assertEq(agents.openPendingCount(agentId), agents.MAX_OPEN_PENDING());
    }
}
