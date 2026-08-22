// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HawkPremiumSale, IERC721Minimal, IERC20Minimal, IAggregatorMinimal} from "../contracts/hawk/HawkPremiumSale.sol";

/// @dev Wave 2: Base team names at a symbolic $100 — goodwill pricing
///      for the chain's own people. Each wave is its own sale instance so
///      listing never needs a Safe ceremony (prices are constructor-set).
contract DeployPremiumSaleWave2 is Script {
    address constant SAFE = 0xD0d82499Bfbbc5D92d31BDc46d31d1Fd3eA50a71;
    address constant REGISTRAR = 0x218CCD54F64cdcB7d0B6e45eA4665846df01Ad5C;
    address constant USDC = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    uint256 constant MAX_FEED_AGE = 129600;

    function run() external {
        string[] memory labels = new string[](4);
        uint256[] memory prices = new uint256[](4);
        (labels[0], prices[0]) = ("baiju", 100e18);
        (labels[1], prices[1]) = ("johann", 100e18);
        (labels[2], prices[2]) = ("jason", 100e18);
        (labels[3], prices[3]) = ("steve", 100e18);

        vm.startBroadcast();
        HawkPremiumSale sale = new HawkPremiumSale(
            HawkPremiumSale.Config({
                safe: SAFE,
                registrar: IERC721Minimal(REGISTRAR),
                usdc: IERC20Minimal(USDC),
                feed: IAggregatorMinimal(FEED),
                maxFeedAge: MAX_FEED_AGE,
                labels: labels,
                pricesAttoUSD: prices
            })
        );
        vm.stopBroadcast();
        console2.log("HawkPremiumSale wave2:", address(sale));
    }
}
