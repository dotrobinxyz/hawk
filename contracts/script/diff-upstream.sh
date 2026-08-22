#!/usr/bin/env bash
# Prints the complete diff between each Hawk contract and its upstream
# ens-contracts v1.7.0 counterpart. This output — plus the new files listed
# at the end — is the entire contract audit surface.
set -euo pipefail
cd "$(dirname "$0")/.."

pair() { # upstream-path hawk-path
  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "  $2  ⇐  $1 (v1.7.0)"
  echo "════════════════════════════════════════════════════════════════"
  diff -u <(git show "v1.7.0:$1") "$2" || true
}

pair contracts/registry/ENSRegistry.sol            contracts/hawk/HawkRegistry.sol
pair contracts/ethregistrar/BaseRegistrarImplementation.sol contracts/hawk/HawkBaseRegistrar.sol
pair contracts/ethregistrar/ETHRegistrarController.sol      contracts/hawk/HawkRegistrarController.sol
pair contracts/wrapper/NameWrapper.sol             contracts/hawk/HawkWrapper.sol

echo
echo "════════════════════════════════════════════════════════════════"
echo "  contracts/hawk/HawkPriceOracle.sol merges StablePriceOracle +"
echo "  ExponentialPremiumPriceOracle; diff against each in turn:"
echo "════════════════════════════════════════════════════════════════"
diff -u <(git show v1.7.0:contracts/ethregistrar/StablePriceOracle.sol) contracts/hawk/HawkPriceOracle.sol || true
diff -u <(git show v1.7.0:contracts/ethregistrar/ExponentialPremiumPriceOracle.sol) contracts/hawk/HawkPriceOracle.sol || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "  New files with no upstream counterpart (review in full):"
echo "════════════════════════════════════════════════════════════════"
ls -1 contracts/hawk/HawkMetadata.sol contracts/hawk/HawkReservedList.sol \
      contracts/hawk/IReservedList.sol contracts/hawk/IHawkPriceOracle.sol \
      contracts/hawk/IHawkRegistrarController.sol contracts/hawk/IHawkTokenURIProvider.sol \
      contracts/hawk/mocks/MockAggregator.sol contracts/hawk/mocks/MockUSDG.sol

echo
echo "Everything else in contracts/ is byte-identical to ens-contracts v1.7.0"
echo "(verify: git diff v1.7.0 -- contracts ':(exclude)contracts/hawk')"
