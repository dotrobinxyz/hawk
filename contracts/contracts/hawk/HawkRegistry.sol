//SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import {ENSRegistry} from "../registry/ENSRegistry.sol";

/// @title HawkRegistry
/// @notice The Hawk registry for Base: `namehash → (owner, resolver, ttl)`
///         for every name in the tree, rooted at the node owned by the deployer.
/// @dev Zero-diff subclass of the audited upstream ENSRegistry (ens-contracts v1.7.0).
///      The subclass exists so the deployed, verified contract carries the Hawk name;
///      all behaviour is inherited unchanged.
contract HawkRegistry is ENSRegistry {}
