//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {IETHRegistrarController, IPriceOracle} from "../ethregistrar/IETHRegistrarController.sol";

/// @notice Hawk's controller interface: the upstream commit-reveal controller
///         interface plus the flat-USDC payment path.
///
///         Amount semantics: `NameRegistered`/`NameRenewed` events always carry
///         the amounts actually paid in the payment asset used — wei for the
///         payable functions, USDC base units for the *WithUSDC functions
///         (which additionally emit `USDCPayment` in the same transaction).
interface IHawkRegistrarController is IETHRegistrarController {
    /// @notice Registers a name, paying the flat USD price in USDC.
    ///         Requires a prior USDC approval for at least the total price.
    /// @param registration The registration to register (same commitment
    ///        struct as the ETH path; commitments are payment-agnostic).
    /// @param maxTotalUSDC Upper bound on the USDC charged (base + premium),
    ///        protecting against price movement between quote and inclusion.
    function registerWithUSDC(
        Registration calldata registration,
        uint256 maxTotalUSDC
    ) external;

    /// @notice Renews a name, paying the flat USD price in USDC.
    /// @param label The label of the name.
    /// @param duration The duration to extend the registration for.
    /// @param referrer The referrer of the renewal.
    /// @param maxTotalUSDC Upper bound on the USDC charged.
    function renewWithUSDC(
        string calldata label,
        uint256 duration,
        bytes32 referrer,
        uint256 maxTotalUSDC
    ) external;

    /// @notice Returns the price of a registration in USDC base units
    ///         (rounded up from the USD price).
    function rentPriceUSDC(
        string calldata label,
        uint256 duration
    ) external view returns (IPriceOracle.Price memory);
}
