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
import {FeeSchedule} from "../src/payments/FeeSchedule.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Mainnet deployment of the Glade protocol on Robinhood Chain.
///
/// Configuration is read from environment variables (.env.example lists them):
///   PRIVATE_KEY                key that signs every deployment; must hold ETH
///                              to pay gas
///   COMPLIANCE_AUTHORITY       account permitted to record KYC results
///   USDG_ADDRESS               ERC-20 that the ConfidentialToken wraps
///   TRANSFER_VERIFIER_ADDRESS  deployed Groth16 verifier. If omitted, the
///                              script deploys a StubTransferVerifier for
///                              bring-up, which accepts every proof.
///
/// Example invocation:
///   forge script script/LaunchMainnet.s.sol:Deploy \
///     --rpc-url robinhood --broadcast \
///     --verify --verifier blockscout
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address compliance = vm.envAddress("COMPLIANCE_AUTHORITY");
        address usdg = vm.envAddress("USDG_ADDRESS");
        address verifierAddr = vm.envOr("TRANSFER_VERIFIER_ADDRESS", address(0));

        vm.startBroadcast(pk);

        ProtocolAuthority protocol = new ProtocolAuthority(compliance);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        AgentController agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        RequestLedger requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        DisclosureLog disclosures = new DisclosureLog(IAccountRegistry(address(registry)));

        if (verifierAddr == address(0)) {
            verifierAddr = address(new StubTransferVerifier());
            console2.log("WARNING: bring-up StubTransferVerifier deployed. Rotate before use.");
        }
        ConfidentialToken confidential = new ConfidentialToken(
            IERC20(usdg), IConfidentialTransferVerifier(verifierAddr), msg.sender
        );

        // Optional fees: when TREASURY is set, a FeeSchedule is deployed and
        // registered on ProtocolAuthority along with the treasury address.
        // Without it, no schedule exists and the protocol charges nothing.
        address treasury = vm.envOr("TREASURY", address(0));
        FeeSchedule feeSchedule;
        if (treasury != address(0)) {
            feeSchedule = new FeeSchedule(msg.sender);
            protocol.setFeeConfig(treasury, address(feeSchedule));
        }

        vm.stopBroadcast();

        console2.log("ProtocolAuthority:  ", address(protocol));
        console2.log("AccountRegistry:    ", address(registry));
        console2.log("AgentController:    ", address(agents));
        console2.log("RequestLedger:      ", address(requests));
        console2.log("DisclosureLog:      ", address(disclosures));
        console2.log("ConfidentialToken:  ", address(confidential));
        console2.log("TransferVerifier:   ", verifierAddr);
        console2.log("FeeSchedule:        ", address(feeSchedule));
    }
}
