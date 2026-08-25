// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";

/// @title SafeTransferLib
/// @notice Smooths over inconsistent ERC-20 return values. A token may report
///         failure with a `false` return or may return no data at all, and
///         several older stablecoins take the second approach. USDG is well
///         behaved, but agent vaults can receive bridged tokens with other
///         conventions, so all transfers are routed here and any unsuccessful
///         call is turned into a revert.
library SafeTransferLib {
    error TransferFailed();
    error TransferFromFailed();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFromFailed();
    }
}
