// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolAuthority} from "../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../src/core/AccountRegistry.sol";
import {AgentController} from "../src/agents/AgentController.sol";
import {RequestLedger} from "../src/payments/RequestLedger.sol";
import {DisclosureLog} from "../src/privacy/DisclosureLog.sol";
import {ConfidentialToken} from "../src/privacy/ConfidentialToken.sol";
import {StubTransferVerifier} from "../src/privacy/StubTransferVerifier.sol";
import {IConfidentialTransferVerifier} from "../src/privacy/IConfidentialTransferVerifier.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "../test/helpers/MockERC20.sol";

/// @notice Deploys a Glade test environment to Robinhood Chain testnet
///         (chain ID 46630).
///
/// Because the testnet has no official USDG, the script deploys a mock token
/// with 6 decimals. It also makes the deployer the compliance authority and
/// wires in the accept-everything stub verifier. None of these shortcuts are
/// acceptable for mainnet, where script/LaunchMainnet.s.sol takes real
/// addresses from .env instead.
///
/// Example invocation:
///   forge script script/LaunchTestnet.s.sol:DeployTestnet \
///     --rpc-url robinhood_testnet --broadcast
contract DeployTestnet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // Mock USDG. The deployer receives a large balance so every flow can
        // be exercised right after deployment.
        MockERC20 usdg = new MockERC20("Global Dollar (Testnet)", "USDG", 6);
        usdg.mint(deployer, 1_000_000e6);

        ProtocolAuthority protocol = new ProtocolAuthority(deployer);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        AgentController agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        RequestLedger requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        DisclosureLog disclosures = new DisclosureLog(IAccountRegistry(address(registry)));

        StubTransferVerifier verifier = new StubTransferVerifier();
        ConfidentialToken confidential = new ConfidentialToken(
            IERC20(address(usdg)), IConfidentialTransferVerifier(address(verifier)), deployer
        );

        vm.stopBroadcast();

        console2.log("Deployer:           ", deployer);
        console2.log("USDG (mock):        ", address(usdg));
        console2.log("ProtocolAuthority:  ", address(protocol));
        console2.log("AccountRegistry:    ", address(registry));
        console2.log("AgentController:    ", address(agents));
        console2.log("RequestLedger:      ", address(requests));
        console2.log("DisclosureLog:      ", address(disclosures));
        console2.log("TransferVerifier:   ", address(verifier));
        console2.log("ConfidentialToken:  ", address(confidential));
    }
}
