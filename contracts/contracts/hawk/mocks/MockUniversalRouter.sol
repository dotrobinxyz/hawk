// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {MockHawkToken} from "./MockHawkToken.sol";

interface IERC20BalanceOnly {
    function balanceOf(address owner) external view returns (uint256);
}

/// @dev UniversalRouter stand-in for buyback tests: the bond contract
///      transfers USDC in and calls execute; the mock converts the fresh
///      USDC to HAWK at a settable rate and mints it to the caller.
contract MockUniversalRouter {
    MockHawkToken public immutable hawk;
    IERC20BalanceOnly public immutable usdc;
    uint256 public hawkPerUsdcWad; // HAWK (18d) per 1 USDC (6d), 1e18-scaled
    uint256 private accounted;

    bytes public lastCommands;

    constructor(MockHawkToken _hawk, IERC20BalanceOnly _usdc, uint256 _hawkPerUsdcWad) {
        hawk = _hawk;
        usdc = _usdc;
        hawkPerUsdcWad = _hawkPerUsdcWad;
    }

    function setRate(uint256 _hawkPerUsdcWad) external {
        hawkPerUsdcWad = _hawkPerUsdcWad;
    }

    function execute(
        bytes calldata commands,
        bytes[] calldata,
        uint256
    ) external payable {
        lastCommands = commands;
        uint256 bal = usdc.balanceOf(address(this));
        uint256 amountIn = bal - accounted;
        accounted = bal;
        uint256 out = (amountIn * hawkPerUsdcWad) / 1e6;
        hawk.mint(msg.sender, out);
    }
}
