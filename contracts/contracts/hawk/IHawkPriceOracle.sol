//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {IPriceOracle} from "../ethregistrar/IPriceOracle.sol";

/// @notice Price oracle interface extended with USD-denominated quotes.
///         Hawk charges flat USD prices payable in USDC, so the controller
///         needs prices in USD as well as in wei.
interface IHawkPriceOracle is IPriceOracle {
    /// @dev Returns the price to register or renew a name, denominated in
    ///      attoUSD (1e-18 USD) instead of wei.
    /// @param name The name being registered or renewed.
    /// @param expires When the name presently expires (0 if this is a new registration).
    /// @param duration How long the name is being registered or extended for, in seconds.
    /// @return base premium tuple of base price + premium price, in attoUSD.
    function priceInUSD(
        string calldata name,
        uint256 expires,
        uint256 duration
    ) external view returns (Price memory);
}
