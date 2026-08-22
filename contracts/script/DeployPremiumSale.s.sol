// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HawkPremiumSale, IERC721Minimal, IERC20Minimal, IAggregatorMinimal} from "../contracts/hawk/HawkPremiumSale.sol";

/// @dev Deploys the premium-name shop on Base mainnet with the
///      curated launch listing. The names themselves are registered TO the
///      deployed contract afterwards (owner = sale), so no Safe ceremony is
///      needed to open the shop; the Safe owns every admin lever.
contract DeployPremiumSale is Script {
    address constant SAFE = 0xD0d82499Bfbbc5D92d31BDc46d31d1Fd3eA50a71;
    address constant REGISTRAR = 0x218CCD54F64cdcB7d0B6e45eA4665846df01Ad5C;
    address constant USDC = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    uint256 constant MAX_FEED_AGE = 129600; // 36h, mirrors HawkPriceOracle

    function run() external {
        string[] memory labels = new string[](16);
        uint256[] memory prices = new uint256[](16);
        (labels[0], prices[0]) = ("vitalik", 2000e18);
        (labels[1], prices[1]) = ("satoshi", 2000e18);
        (labels[2], prices[2]) = ("elon", 2000e18);
        (labels[3], prices[3]) = ("brian", 1500e18);
        (labels[4], prices[4]) = ("jesse", 1500e18);
        (labels[5], prices[5]) = ("hayden", 1500e18);
        (labels[6], prices[6]) = ("sergey", 1500e18);
        (labels[7], prices[7]) = ("anatoly", 1500e18);
        (labels[8], prices[8]) = ("saylor", 1500e18);
        (labels[9], prices[9]) = ("balaji", 1500e18);
        (labels[10], prices[10]) = ("naval", 1500e18);
        (labels[11], prices[11]) = ("stani", 1000e18);
        (labels[12], prices[12]) = ("cobie", 1000e18);
        (labels[13], prices[13]) = ("ansem", 1000e18);
        (labels[14], prices[14]) = ("gcr", 1000e18);
        (labels[15], prices[15]) = ("justin", 1000e18);

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
        console2.log("HawkPremiumSale:", address(sale));
    }
}
