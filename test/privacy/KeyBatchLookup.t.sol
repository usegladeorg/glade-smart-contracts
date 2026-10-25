// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AltBn128} from "../../src/privacy/AltBn128.sol";
import {ConfidentialToken} from "../../src/privacy/ConfidentialToken.sol";
import {StubTransferVerifier} from "../../src/privacy/StubTransferVerifier.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

contract ConfidentialKeyBatchTest is Test {
    ConfidentialToken confidential;

    address admin = makeAddr("admin");
    address felix = makeAddr("felix");
    address gwen = makeAddr("gwen");
    address theo = makeAddr("theo");

    AltBn128.Point gwenKey;

    function setUp() public {
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        confidential =
            new ConfidentialToken(IERC20(address(usdg)), new StubTransferVerifier(), admin);

        vm.prank(felix);
        confidential.register(1, 2);

        gwenKey = AltBn128.encode(0xdeadbeef);
        vm.prank(gwen);
        confidential.register(gwenKey.x, gwenKey.y);
    }

    function test_returns_keys_in_requested_order() public view {
        address[] memory accounts = new address[](2);
        accounts[0] = gwen;
        accounts[1] = felix;

        AltBn128.Point[] memory keys = confidential.publicKeysOf(accounts);
        assertEq(keys.length, 2);
        assertEq(keys[0].x, gwenKey.x);
        assertEq(keys[0].y, gwenKey.y);
        assertEq(keys[1].x, 1);
        assertEq(keys[1].y, 2);
    }

    function test_matches_single_lookup() public view {
        address[] memory accounts = new address[](1);
        accounts[0] = gwen;

        AltBn128.Point[] memory keys = confidential.publicKeysOf(accounts);
        (uint256 x, uint256 y) = confidential.publicKeyOf(gwen);
        assertEq(keys[0].x, x);
        assertEq(keys[0].y, y);
    }

    function test_unregistered_account_returns_zero_point() public view {
        address[] memory accounts = new address[](1);
        accounts[0] = theo;

        AltBn128.Point[] memory keys = confidential.publicKeysOf(accounts);
        assertEq(keys[0].x, 0);
        assertEq(keys[0].y, 0);
    }
}
