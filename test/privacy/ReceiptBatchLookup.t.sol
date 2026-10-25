// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {DisclosureLog} from "../../src/privacy/DisclosureLog.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../../src/interfaces/IAccountRegistry.sol";

contract DisclosureBatchLookupTest is Test {
    DisclosureLog disclosures;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");

    function setUp() public {
        ProtocolAuthority protocol = new ProtocolAuthority(compliance);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        disclosures = new DisclosureLog(IAccountRegistry(address(registry)));

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);

        vm.startPrank(gwen);
        disclosures.file("tx-a", keccak256("auditor"), keccak256("proof-a"));
        disclosures.file("tx-b", keccak256("auditor"), keccak256("proof-b"));
        disclosures.file("tx-c", keccak256("auditor"), keccak256("proof-c"));
        vm.stopPrank();
    }

    function test_returns_receipts_in_requested_order() public view {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 3;
        ids[1] = 1;

        DisclosureLog.DisclosureReceipt[] memory got = disclosures.getReceipts(ids);
        assertEq(got.length, 2);
        assertEq(got[0].txReference, "tx-c");
        assertEq(got[1].txReference, "tx-a");
    }

    function test_unknown_ids_come_back_empty() public view {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 99;

        DisclosureLog.DisclosureReceipt[] memory got = disclosures.getReceipts(ids);
        assertTrue(got[0].exists);
        assertFalse(got[1].exists);
        assertEq(got[1].profile, address(0));
    }

    function test_works_with_a_page_of_ids() public view {
        DisclosureLog.DisclosureReceipt[] memory got =
            disclosures.getReceipts(disclosures.receiptIdsOf(gwen, 1, 2));
        assertEq(got.length, 2);
        assertEq(got[0].txReference, "tx-b");
        assertEq(got[1].txReference, "tx-c");
    }
}
