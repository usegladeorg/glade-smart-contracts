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

/// @notice Agent creation requires the policy token to be a deployed contract.
contract AgentTokenTest is Test {
    AgentController agents;
    MockERC20 usdg;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        ProtocolAuthority protocol = new ProtocolAuthority(compliance);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
    }

    function _create(address token) internal returns (uint256) {
        address[] memory none = new address[](0);
        vm.prank(gwen);
        return agents.createAgent(
            makeAddr("signer"),
            "coding-assistant",
            AgentController.AutonomyTier.SemiAutonomous,
            token,
            10e6,
            50e6,
            5e6,
            none,
            false
        );
    }

    function test_agent_for_a_token_with_no_code_reverts() public {
        vm.expectRevert(InvalidToken.selector);
        _create(makeAddr("wallet"));
        assertEq(agents.agentCount(), 0);
    }

    function test_agent_for_a_real_token_still_works() public {
        uint256 agentId = _create(address(usdg));
        assertEq(agents.getPolicy(agentId).token, address(usdg));
    }
}
