//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

/// @notice Minimal read interface for Hawk's reserved-name list.
interface IReservedList {
    /// @dev Returns true if the label (identified by its keccak256 hash) is
    ///      reserved and must not be registered by the public controller.
    function isLabelhashReserved(bytes32 labelhash) external view returns (bool);
}
