// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @dev Uniswap v4 StateView stand-in: one settable sqrtPriceX96 returned
///      for every pool id.
contract MockStateView {
    uint160 public sqrtPriceX96;

    constructor(uint160 _sqrtPriceX96) {
        sqrtPriceX96 = _sqrtPriceX96;
    }

    function set(uint160 _sqrtPriceX96) external {
        sqrtPriceX96 = _sqrtPriceX96;
    }

    function getSlot0(
        bytes32
    ) external view returns (uint160, int24, uint24, uint24) {
        return (sqrtPriceX96, 0, 0, 0);
    }
}
