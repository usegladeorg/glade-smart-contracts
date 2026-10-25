// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {AgentController} from "../../src/agents/AgentController.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../../src/interfaces/IAccountRegistry.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

contract AgentOwnerPagingTest is Test {
    AgentController agents;
    MockERC20 usdg;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address signer = makeAddr("signer");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        ProtocolAuthority protocol = new ProtocolAuthority(compliance);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.AgentOperator);

        address[] memory none = new address[](0);
        vm.startPrank(gwen);
        for (uint256 i; i < 3; ++i) {
            agents.createAgent(
                signer,
                "worker",
                AgentController.AutonomyTier.Supervised,
                address(usdg),
                10e6,
                50e6,
                5e6,
                none,
                false
            );
        }
        vm.stopPrank();
    }

    function test_pages_follow_creation_order() public view {
        uint256[] memory first = agents.agentIdsOf(gwen, 0, 2);
        assertEq(first.length, 2);
        assertEq(first[0], 1);
        assertEq(first[1], 2);

        uint256[] memory second = agents.agentIdsOf(gwen, 2, 2);
        assertEq(second.length, 1);
        assertEq(second[0], 3);

        assertEq(agents.agentIdsOf(gwen, 3, 2).length, 0);
    }

    function test_max_limit_returns_the_rest() public view {
        uint256[] memory page = agents.agentIdsOf(gwen, 1, type(uint256).max);
        assertEq(page.length, 2);
        assertEq(page[0], 2);
        assertEq(page[1], 3);
    }

    function test_unknown_owner_gets_empty_page() public view {
        assertEq(agents.agentIdsOf(address(0xBEEF), 0, 10).length, 0);
    }
}
