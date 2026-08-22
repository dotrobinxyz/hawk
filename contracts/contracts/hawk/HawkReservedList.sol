//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IReservedList} from "./IReservedList.sol";

/// @title HawkReservedList
/// @notice The owner-updatable list of labels that the public controller must
///         not sell: stock tickers tradeable on Base, prominent
///         chain protocol and brand names, and a profanity/impersonation
///         blocklist. Reserving a label only blocks *new* registrations; it
///         never affects names already registered or their renewals.
/// @dev New contract, no upstream counterpart. Kept deliberately dumb: a
///      labelhash → bool mapping with batch setters. To release or sell a
///      reserved name later, the owner removes it from the list and registers
///      it through the normal controller flow.
contract HawkReservedList is Ownable, IReservedList {
    /// @notice True for every labelhash that is currently reserved.
    mapping(bytes32 => bool) public reservedLabelhashes;

    /// @notice Emitted whenever a label's reservation status changes.
    /// @param labelhash The keccak256 hash of the label.
    /// @param label The plaintext label ("" when set via hash, e.g. bulk imports).
    /// @param reserved The new reservation status.
    event ReservationChanged(bytes32 indexed labelhash, string label, bool reserved);

    /// @notice Sets the reservation status for a batch of plaintext labels.
    function setReserved(
        string[] calldata labels,
        bool reserved
    ) external onlyOwner {
        for (uint256 i = 0; i < labels.length; i++) {
            bytes32 labelhash = keccak256(bytes(labels[i]));
            reservedLabelhashes[labelhash] = reserved;
            emit ReservationChanged(labelhash, labels[i], reserved);
        }
    }

    /// @notice Sets the reservation status for a batch of labelhashes.
    ///         Cheaper for large imports; emits events without plaintext.
    function setReservedHashes(
        bytes32[] calldata labelhashes,
        bool reserved
    ) external onlyOwner {
        for (uint256 i = 0; i < labelhashes.length; i++) {
            reservedLabelhashes[labelhashes[i]] = reserved;
            emit ReservationChanged(labelhashes[i], "", reserved);
        }
    }

    /// @inheritdoc IReservedList
    function isLabelhashReserved(
        bytes32 labelhash
    ) external view returns (bool) {
        return reservedLabelhashes[labelhash];
    }

    /// @notice Convenience view for apps: checks a plaintext label.
    function isReserved(string calldata label) external view returns (bool) {
        return reservedLabelhashes[keccak256(bytes(label))];
    }
}
