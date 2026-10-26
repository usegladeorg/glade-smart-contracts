// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {FeeSchedule} from "../../src/payments/FeeSchedule.sol";
import {ConfidentialToken} from "../../src/privacy/ConfidentialToken.sol";
import {StubTransferVerifier} from "../../src/privacy/StubTransferVerifier.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import "../../src/utils/ProtocolErrors.sol";

contract AuthoritySelfNominationTest is Test {
    ProtocolAuthority protocol;
    FeeSchedule fees;
    ConfidentialToken confidential;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address multisig = makeAddr("multisig");

    function setUp() public {
        vm.prank(admin);
        protocol = new ProtocolAuthority(compliance);
        fees = new FeeSchedule(admin);
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        confidential =
            new ConfidentialToken(IERC20(address(usdg)), new StubTransferVerifier(), admin);
    }

    function test_protocol_rejects_self_nomination() public {
        vm.expectRevert(AlreadyAuthority.selector);
        vm.prank(admin);
        protocol.beginAuthorityTransfer(admin);
    }

    function test_fee_schedule_rejects_self_nomination() public {
        vm.expectRevert(AlreadyAuthority.selector);
        vm.prank(admin);
        fees.beginAuthorityTransfer(admin);
    }

    function test_confidential_token_rejects_self_nomination() public {
        vm.expectRevert(AlreadyAuthority.selector);
        vm.prank(admin);
        confidential.beginAuthorityTransfer(admin);
    }

    function test_nominating_someone_else_and_cancelling_still_work() public {
        vm.startPrank(admin);
        protocol.beginAuthorityTransfer(multisig);
        assertEq(protocol.pendingAuthority(), multisig);
        protocol.beginAuthorityTransfer(address(0));
        assertEq(protocol.pendingAuthority(), address(0));
        vm.stopPrank();
    }
}
