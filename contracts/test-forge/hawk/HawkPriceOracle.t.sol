//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {HawkFixture} from "./HawkFixture.sol";
import {HawkPriceOracle, AggregatorV3Interface} from "../../contracts/hawk/HawkPriceOracle.sol";
import {ExponentialPremiumPriceOracle, AggregatorInterface} from "../../contracts/ethregistrar/ExponentialPremiumPriceOracle.sol";
import {IPriceOracle} from "../../contracts/ethregistrar/IPriceOracle.sol";

contract HawkPriceOracleTest is HawkFixture {
    uint256 constant YEAR = 365 days;

    ExponentialPremiumPriceOracle upstream;

    function setUp() public override {
        super.setUp();
        uint256[] memory rates = new uint256[](5);
        rates[0] = RATE3;
        rates[1] = RATE3;
        rates[2] = RATE3;
        rates[3] = RATE4;
        rates[4] = RATE5;
        upstream = new ExponentialPremiumPriceOracle(
            AggregatorInterface(address(feed)),
            rates,
            PREMIUM_START,
            PREMIUM_DAYS
        );
    }

    // ------------------------------------------------------------------
    // base pricing
    // ------------------------------------------------------------------

    function test_usdPricingTable() public view {
        // exact attoUSD amounts for one year
        assertEq(
            oracle.priceInUSD("abc", 0, YEAR).base,
            RATE3 * YEAR
        );
        assertEq(oracle.priceInUSD("abcd", 0, YEAR).base, RATE4 * YEAR);
        assertEq(oracle.priceInUSD("abcde", 0, YEAR).base, RATE5 * YEAR);
        assertEq(
            oracle.priceInUSD("a-very-long-name", 0, YEAR).base,
            RATE5 * YEAR
        );
        // ~1e-10 USD under the flat price, matching upstream truncation
        assertApproxEqAbs(oracle.priceInUSD("abc", 0, YEAR).base, 100e18, 2e7);
        assertApproxEqAbs(oracle.priceInUSD("abcd", 0, YEAR).base, 25e18, 2e7);
        assertApproxEqAbs(oracle.priceInUSD("abcde", 0, YEAR).base, 5e18, 3e7);
    }

    function test_weiConversionUsesFeed() public {
        // $5 at $2000 = 0.0025 ETH
        assertApproxEqAbs(
            oracle.price("abcde", 0, YEAR).base,
            0.0025 ether,
            1e6
        );
        // price doubles when ETH halves
        feed.set(1000e8);
        assertApproxEqAbs(
            oracle.price("abcde", 0, YEAR).base,
            0.005 ether,
            1e6
        );
    }

    /// @dev Base pricing (no promo, no premium) must match upstream exactly.
    function testFuzz_basePriceMatchesUpstream(
        uint8 rawLen,
        uint32 durationDays
    ) public view {
        uint256 len = bound(rawLen, 1, 30);
        uint256 duration = bound(durationDays, 1, 3650) * 1 days;
        bytes memory label = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            label[i] = "a";
        }
        string memory name = string(label);
        IPriceOracle.Price memory ours = oracle.price(name, 0, duration);
        IPriceOracle.Price memory theirs = upstream.price(name, 0, duration);
        assertEq(ours.base, theirs.base);
        assertEq(ours.premium, theirs.premium);
    }

    // ------------------------------------------------------------------
    // launch promo
    // ------------------------------------------------------------------

    function test_promoHalvesFivePlusOnly_andExpires() public {
        uint256 promoEnd = block.timestamp + 14 days;
        HawkPriceOracle promoOracle = _deployOracle(promoEnd);

        // inside window: 5+ char halved, 3/4 char untouched
        assertEq(
            promoOracle.priceInUSD("abcde", 0, YEAR).base,
            (RATE5 * YEAR) / 2
        );
        assertEq(promoOracle.priceInUSD("abc", 0, YEAR).base, RATE3 * YEAR);
        assertEq(promoOracle.priceInUSD("abcd", 0, YEAR).base, RATE4 * YEAR);

        // boundary: last second of the window still discounted
        vm.warp(promoEnd - 1);
        assertEq(
            promoOracle.priceInUSD("abcde", 0, YEAR).base,
            (RATE5 * YEAR) / 2
        );

        // at/after promoEnd: full price
        vm.warp(promoEnd);
        assertEq(promoOracle.priceInUSD("abcde", 0, YEAR).base, RATE5 * YEAR);
    }

    function test_promoDoesNotDiscountPremium() public {
        uint256 promoEnd = block.timestamp + 3650 days; // promo "always on"
        HawkPriceOracle promoOracle = _deployOracle(promoEnd);
        uint256 expires = block.timestamp - GRACE; // premium just started
        IPriceOracle.Price memory p = promoOracle.priceInUSD(
            "abcde",
            expires,
            YEAR
        );
        assertEq(p.base, (RATE5 * YEAR) / 2);
        // full $1,000-minus-endvalue premium, undiscounted
        assertApproxEqAbs(p.premium, 1000e18, 1e15);
    }

    // ------------------------------------------------------------------
    // expiry premium (Dutch auction)
    // ------------------------------------------------------------------

    function test_premiumWindow() public {
        uint256 expires = block.timestamp;
        // during registration/grace: no premium
        assertEq(oracle.priceInUSD("abcde", expires, YEAR).premium, 0);
        vm.warp(expires + GRACE - 1);
        assertEq(oracle.priceInUSD("abcde", expires, YEAR).premium, 0);

        // the auction opens at the exact grace-end second (upstream `>`),
        // one second before the name becomes available (registrar `<`)
        vm.warp(expires + GRACE);
        assertApproxEqAbs(
            oracle.priceInUSD("abcde", expires, YEAR).premium,
            1000e18,
            1e16
        );

        // just after grace end: ~$1,000
        vm.warp(expires + GRACE + 1);
        assertApproxEqAbs(
            oracle.priceInUSD("abcde", expires, YEAR).premium,
            1000e18,
            1e16
        );

        // halves daily
        vm.warp(expires + GRACE + 1 days);
        assertApproxEqAbs(
            oracle.priceInUSD("abcde", expires, YEAR).premium,
            500e18,
            1e15
        );

        // reaches exactly 0 at day 21 and stays there
        vm.warp(expires + GRACE + 21 days);
        assertEq(oracle.priceInUSD("abcde", expires, YEAR).premium, 0);
        vm.warp(expires + GRACE + 400 days);
        assertEq(oracle.priceInUSD("abcde", expires, YEAR).premium, 0);
    }

    /// @dev The decay curve must match upstream's bit-for-bit at all elapsed
    ///      times (same math, same constants).
    function testFuzz_premiumMatchesUpstream(uint32 elapsedSeconds) public view {
        uint256 elapsed = bound(elapsedSeconds, 0, 30 days);
        assertEq(
            oracle.decayedPremium(PREMIUM_START, elapsed),
            upstream.decayedPremium(PREMIUM_START, elapsed)
        );
    }

    /// @dev Full price parity with upstream across the premium window
    ///      (both use 90-day grace).
    function testFuzz_fullPriceMatchesUpstream(
        uint32 sinceExpiry
    ) public {
        uint256 expires = block.timestamp;
        vm.warp(expires + bound(sinceExpiry, 0, 120 days));
        IPriceOracle.Price memory ours = oracle.price("abcde", expires, YEAR);
        IPriceOracle.Price memory theirs = upstream.price(
            "abcde",
            expires,
            YEAR
        );
        assertEq(ours.base, theirs.base);
        assertEq(ours.premium, theirs.premium);
    }

    // ------------------------------------------------------------------
    // feed safety
    // ------------------------------------------------------------------

    function test_staleFeedRevertsETHPathOnly() public {
        feed.setUpdatedAt(START_TIME);
        vm.warp(block.timestamp + MAX_FEED_AGE + 1);
        // feed.updatedAt pinned at START_TIME → stale
        vm.expectRevert(
            abi.encodeWithSelector(
                HawkPriceOracle.StaleFeed.selector,
                START_TIME,
                MAX_FEED_AGE
            )
        );
        oracle.price("abcde", 0, YEAR);

        // USD path unaffected
        assertEq(oracle.priceInUSD("abcde", 0, YEAR).base, RATE5 * YEAR);
    }

    function test_nonPositiveAnswerReverts() public {
        feed.set(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                HawkPriceOracle.InvalidFeedAnswer.selector,
                int256(0)
            )
        );
        oracle.price("abcde", 0, YEAR);

        feed.set(-1);
        vm.expectRevert(
            abi.encodeWithSelector(
                HawkPriceOracle.InvalidFeedAnswer.selector,
                int256(-1)
            )
        );
        oracle.price("abcde", 0, YEAR);
    }
}
