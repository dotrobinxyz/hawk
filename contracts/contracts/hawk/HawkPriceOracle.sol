//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import "../ethregistrar/IPriceOracle.sol";
import "./IHawkPriceOracle.sol";
import "../utils/StringUtils.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Chainlink AggregatorV3 subset. Hawk uses `latestRoundData` (with
///      staleness checks) instead of upstream's deprecated `latestAnswer`.
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title HawkPriceOracle
/// @notice USD-denominated pricing for .hawk names:
///         - length-based annual base prices ($100 3-char, $25 4-char, $5 5+),
///         - a launch promo window halving 5+ char base prices,
///         - an exponential Dutch-auction premium after expiry + grace
///           ($1,000 decaying to ~$0 over 21 days, upstream's exact math),
///         - quotes in wei (via the chain's Chainlink ETH/USD feed) and in
///           attoUSD (for the flat-USDC payment path).
///
/// @dev Merged copy of upstream StablePriceOracle + ExponentialPremiumPriceOracle
///      (ens-contracts v1.7.0). Deliberate diffs — everything else, including
///      the premium decay math and its bit constants, is verbatim:
///      1. `priceInUSD` added (IHawkPriceOracle): same computation, returned
///         in attoUSD before ETH conversion. Base-price computation is shared
///         via `_priceAttoUSD` instead of living inline in `price`.
///      2. Launch promo: while `block.timestamp < promoEnd`, base prices for
///         names of 5+ characters are halved. Premiums are never discounted.
///         `promoEnd` is immutable; pass 0 for no promo.
///      3. ETH/USD is read via `latestRoundData` and reverts on a
///         non-positive answer or a stale update (older than `maxFeedAge`).
///         Upstream used `latestAnswer` with no checks. If the feed halts,
///         ETH quoting reverts while the USDC path keeps working.
///      4. GRACE_PERIOD and the premium decay period are constructor
///         arguments instead of constants (mainnet: 90 days / 21 days, the
///         upstream values) so the full lifecycle can be rehearsed on
///         testnet with shortened timers. GRACE_PERIOD must equal the base
///         registrar's.
contract HawkPriceOracle is IHawkPriceOracle {
    using StringUtils for *;

    // Rent in base price units by length
    uint256 public immutable price1Letter;
    uint256 public immutable price2Letter;
    uint256 public immutable price3Letter;
    uint256 public immutable price4Letter;
    uint256 public immutable price5Letter;

    // Oracle address
    AggregatorV3Interface public immutable usdOracle;

    /// @notice Maximum age of the ETH/USD answer before ETH quoting reverts.
    uint256 public immutable maxFeedAge;

    /// @notice End of the launch promo window (50% off 5+ char base prices).
    ///         0 means no promo.
    uint256 public immutable promoEnd;

    /// @notice Grace period after expiry before the premium auction starts.
    ///         Must equal the base registrar's GRACE_PERIOD.
    uint256 public immutable GRACE_PERIOD;

    uint256 immutable startPremium;
    uint256 immutable endValue;

    /// @notice Thrown when the price feed returns a non-positive answer.
    error InvalidFeedAnswer(int256 answer);

    /// @notice Thrown when the price feed's last update is older than maxFeedAge.
    error StaleFeed(uint256 updatedAt, uint256 maxFeedAge);

    constructor(
        AggregatorV3Interface _usdOracle,
        uint256 _maxFeedAge,
        uint256[] memory _rentPrices,
        uint256 _startPremium,
        uint256 _totalDays,
        uint256 _gracePeriod,
        uint256 _promoEnd
    ) {
        usdOracle = _usdOracle;
        maxFeedAge = _maxFeedAge;
        price1Letter = _rentPrices[0];
        price2Letter = _rentPrices[1];
        price3Letter = _rentPrices[2];
        price4Letter = _rentPrices[3];
        price5Letter = _rentPrices[4];
        startPremium = _startPremium;
        endValue = _startPremium >> _totalDays;
        GRACE_PERIOD = _gracePeriod;
        promoEnd = _promoEnd;
    }

    function price(
        string calldata name,
        uint256 expires,
        uint256 duration
    ) external view override returns (IPriceOracle.Price memory) {
        (uint256 basePrice, uint256 premiumPrice) = _priceAttoUSD(
            name,
            expires,
            duration
        );
        return
            IPriceOracle.Price({
                base: attoUSDToWei(basePrice),
                premium: attoUSDToWei(premiumPrice)
            });
    }

    /// @inheritdoc IHawkPriceOracle
    function priceInUSD(
        string calldata name,
        uint256 expires,
        uint256 duration
    ) external view override returns (IPriceOracle.Price memory) {
        (uint256 basePrice, uint256 premiumPrice) = _priceAttoUSD(
            name,
            expires,
            duration
        );
        return IPriceOracle.Price({base: basePrice, premium: premiumPrice});
    }

    /// @dev Shared base+premium computation in attoUSD (upstream: inline in
    ///      `price`), including the launch promo on 5+ char base prices.
    function _priceAttoUSD(
        string calldata name,
        uint256 expires,
        uint256 duration
    ) internal view returns (uint256 basePrice, uint256 premiumPrice) {
        uint256 len = name.strlen();

        if (len >= 5) {
            basePrice = price5Letter * duration;
            // Hawk diff (2): launch promo halves 5+ char base prices.
            if (block.timestamp < promoEnd) {
                basePrice = basePrice / 2;
            }
        } else if (len == 4) {
            basePrice = price4Letter * duration;
        } else if (len == 3) {
            basePrice = price3Letter * duration;
        } else if (len == 2) {
            basePrice = price2Letter * duration;
        } else {
            basePrice = price1Letter * duration;
        }

        premiumPrice = _premium(name, expires, duration);
    }

    /// @dev Returns the pricing premium in wei.
    function premium(
        string calldata name,
        uint256 expires,
        uint256 duration
    ) external view returns (uint256) {
        return attoUSDToWei(_premium(name, expires, duration));
    }

    /// @dev Returns the pricing premium in internal base units.
    function _premium(
        string memory,
        uint256 expires,
        uint256
    ) internal view returns (uint256) {
        expires = expires + GRACE_PERIOD;
        if (expires > block.timestamp) {
            return 0;
        }

        uint256 elapsed = block.timestamp - expires;
        uint256 premiumAmount = decayedPremium(startPremium, elapsed);
        if (premiumAmount >= endValue) {
            return premiumAmount - endValue;
        }
        return 0;
    }

    uint256 constant PRECISION = 1e18;
    uint256 constant bit1 = 999989423469314432; // 0.5 ^ 1/65536 * (10 ** 18)
    uint256 constant bit2 = 999978847050491904; // 0.5 ^ 2/65536 * (10 ** 18)
    uint256 constant bit3 = 999957694548431104;
    uint256 constant bit4 = 999915390886613504;
    uint256 constant bit5 = 999830788931929088;
    uint256 constant bit6 = 999661606496243712;
    uint256 constant bit7 = 999323327502650752;
    uint256 constant bit8 = 998647112890970240;
    uint256 constant bit9 = 997296056085470080;
    uint256 constant bit10 = 994599423483633152;
    uint256 constant bit11 = 989228013193975424;
    uint256 constant bit12 = 978572062087700096;
    uint256 constant bit13 = 957603280698573696;
    uint256 constant bit14 = 917004043204671232;
    uint256 constant bit15 = 840896415253714560;
    uint256 constant bit16 = 707106781186547584;

    /// @dev Returns the premium price at current time elapsed
    /// @param _startPremium starting price
    /// @param elapsed time past since expiry
    function decayedPremium(
        uint256 _startPremium,
        uint256 elapsed
    ) public pure returns (uint256) {
        uint256 daysPast = (elapsed * PRECISION) / 1 days;
        uint256 intDays = daysPast / PRECISION;
        uint256 premiumAmount = _startPremium >> intDays;
        uint256 partDay = (daysPast - intDays * PRECISION);
        uint256 fraction = (partDay * (2 ** 16)) / PRECISION;
        uint256 totalPremium = addFractionalPremium(fraction, premiumAmount);
        return totalPremium;
    }

    function addFractionalPremium(
        uint256 fraction,
        uint256 premiumAmount
    ) internal pure returns (uint256) {
        if (fraction & (1 << 0) != 0) {
            premiumAmount = (premiumAmount * bit1) / PRECISION;
        }
        if (fraction & (1 << 1) != 0) {
            premiumAmount = (premiumAmount * bit2) / PRECISION;
        }
        if (fraction & (1 << 2) != 0) {
            premiumAmount = (premiumAmount * bit3) / PRECISION;
        }
        if (fraction & (1 << 3) != 0) {
            premiumAmount = (premiumAmount * bit4) / PRECISION;
        }
        if (fraction & (1 << 4) != 0) {
            premiumAmount = (premiumAmount * bit5) / PRECISION;
        }
        if (fraction & (1 << 5) != 0) {
            premiumAmount = (premiumAmount * bit6) / PRECISION;
        }
        if (fraction & (1 << 6) != 0) {
            premiumAmount = (premiumAmount * bit7) / PRECISION;
        }
        if (fraction & (1 << 7) != 0) {
            premiumAmount = (premiumAmount * bit8) / PRECISION;
        }
        if (fraction & (1 << 8) != 0) {
            premiumAmount = (premiumAmount * bit9) / PRECISION;
        }
        if (fraction & (1 << 9) != 0) {
            premiumAmount = (premiumAmount * bit10) / PRECISION;
        }
        if (fraction & (1 << 10) != 0) {
            premiumAmount = (premiumAmount * bit11) / PRECISION;
        }
        if (fraction & (1 << 11) != 0) {
            premiumAmount = (premiumAmount * bit12) / PRECISION;
        }
        if (fraction & (1 << 12) != 0) {
            premiumAmount = (premiumAmount * bit13) / PRECISION;
        }
        if (fraction & (1 << 13) != 0) {
            premiumAmount = (premiumAmount * bit14) / PRECISION;
        }
        if (fraction & (1 << 14) != 0) {
            premiumAmount = (premiumAmount * bit15) / PRECISION;
        }
        if (fraction & (1 << 15) != 0) {
            premiumAmount = (premiumAmount * bit16) / PRECISION;
        }
        return premiumAmount;
    }

    /// @dev Hawk diff (3): checked feed read.
    function _ethPrice() internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = usdOracle.latestRoundData();
        if (answer <= 0) {
            revert InvalidFeedAnswer(answer);
        }
        if (
            updatedAt > block.timestamp ||
            block.timestamp - updatedAt > maxFeedAge
        ) {
            revert StaleFeed(updatedAt, maxFeedAge);
        }
        return uint256(answer);
    }

    function attoUSDToWei(uint256 amount) internal view returns (uint256) {
        uint256 ethPrice = _ethPrice();
        return (amount * 1e8) / ethPrice;
    }

    function weiToAttoUSD(uint256 amount) internal view returns (uint256) {
        uint256 ethPrice = _ethPrice();
        return (amount * ethPrice) / 1e8;
    }

    function supportsInterface(
        bytes4 interfaceID
    ) public view virtual returns (bool) {
        return
            interfaceID == type(IERC165).interfaceId ||
            interfaceID == type(IPriceOracle).interfaceId ||
            interfaceID == type(IHawkPriceOracle).interfaceId;
    }
}
