// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAuthority} from "../../src/core/ProtocolAuthority.sol";
import {AccountRegistry} from "../../src/core/AccountRegistry.sol";
import {DisclosureLog} from "../../src/privacy/DisclosureLog.sol";
import {IProtocolAuthority} from "../../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../../src/interfaces/IAccountRegistry.sol";

contract DisclosureTransferPagingTest is Test {
    DisclosureLog disclosures;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address theo = makeAddr("theo");

    function setUp() public {
        ProtocolAuthority protocol = new ProtocolAuthority(compliance);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        disclosures = new DisclosureLog(IAccountRegistry(address(registry)));

        vm.prank(gwen);
        registry.createProfile("gwen", AccountRegistry.AccountKind.Personal);
        vm.prank(theo);
        registry.createProfile("theo", AccountRegistry.AccountKind.Personal);

        // Both sides of tx-shared disclose it, interleaved with an unrelated receipt.
        vm.prank(gwen);
        disclosures.file("tx-shared", keccak256("auditor-a"), keccak256("proof-1"));
        vm.prank(gwen);
        disclosures.file("tx-other", keccak256("auditor-a"), keccak256("proof-2"));
        vm.prank(theo);
        disclosures.file("tx-shared", keccak256("auditor-b"), keccak256("proof-3"));
        vm.prank(gwen);
        disclosures.file("tx-shared", keccak256("auditor-c"), keccak256("proof-4"));
    }

    function test_count_matches_full_list() public view {
        assertEq(disclosures.receiptCountForTransfer("tx-shared"), 3);
        assertEq(disclosures.receiptCountForTransfer("tx-other"), 1);
        assertEq(disclosures.receiptCountForTransfer("tx-missing"), 0);
    }

    function test_pages_follow_filing_order() public view {
        uint256[] memory first = disclosures.receiptIdsForTransfer("tx-shared", 0, 2);
        assertEq(first.length, 2);
        assertEq(first[0], 1);
        assertEq(first[1], 3);

        uint256[] memory second = disclosures.receiptIdsForTransfer("tx-shared", 2, 2);
        assertEq(second.length, 1);
        assertEq(second[0], 4);

        assertEq(disclosures.receiptIdsForTransfer("tx-shared", 3, 2).length, 0);
    }

    function test_max_limit_returns_the_rest() public view {
        uint256[] memory page = disclosures.receiptIdsForTransfer("tx-shared", 1, type(uint256).max);
        assertEq(page.length, 2);
        assertEq(page[0], 3);
        assertEq(page[1], 4);
    }
}
