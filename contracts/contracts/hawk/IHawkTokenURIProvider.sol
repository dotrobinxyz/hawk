//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

/// @notice Renders ERC-721 metadata for the Hawk base registrar. Split out so
///         the registrar's art can be upgraded by the owner without touching
///         registration state.
interface IHawkTokenURIProvider {
    /// @dev Returns a data: URI with full metadata JSON for a .hawk second-level
    ///      name held as an ERC-721. `id` is uint256(labelhash).
    function tokenURI721(uint256 id) external view returns (string memory);

    /// @dev Returns a data: URI with contract-level (collection) metadata for
    ///      marketplaces.
    function contractURI() external view returns (string memory);
}
