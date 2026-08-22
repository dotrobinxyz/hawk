# Robin — contract audit surface

Robin is a fork of [`ensdomains/ens-contracts`](https://github.com/ensdomains/ens-contracts)
pinned at **v1.7.0** (`9b034936a42f462fc04bc0a929a419ede5e18d59`). Every
upstream file under `contracts/` is **byte-identical** to the tag — verify with:

```
git diff v1.7.0 -- contracts ':(exclude)contracts/robin'   # must be empty
```

All Robin work is additive, under `contracts/robin/`. The complete diff against
upstream counterparts prints with `./script/diff-upstream.sh`. Each file's
header comment lists its own deltas; this document is the roll-up.

## Deployed set

| Contract | Basis | Delta class |
|---|---|---|
| RobinRegistry | ENSRegistry | zero-diff subclass (name only) |
| RobinBaseRegistrar | BaseRegistrarImplementation | copy, 5 documented diffs |
| RobinRegistrarController | ETHRegistrarController | copy, 7 documented diffs |
| RobinPriceOracle | StablePriceOracle + ExponentialPremiumPriceOracle | merged copy, 4 documented diffs |
| RobinWrapper | NameWrapper | copy, value-level diffs (~50 code lines) |
| RobinMetadata | — | new (view-only renderer) |
| RobinReservedList | — | new (owner-updatable mapping) |
| PublicResolver, ReverseRegistrar, DefaultReverseRegistrar, UniversalResolver, GatewayProvider | upstream | zero diff, deployed as-is |

## The diffs, by justification

**TLD retarget (controller, wrapper).** `ETH_NODE`/`ETH_LABELHASH` values →
`namehash('robin')`/`keccak256('robin')`; DNS-encoded `"\x03eth\x00"` →
`"\x05robin\x00"` (2 sites in the wrapper — constructor and `_wrapETH2LD`);
reverse-record suffix `".eth"` → `".robin"`. Public function names
(`wrapETH2LD` etc.) are deliberately retained for tooling compatibility.

**Dual payment (controller, oracle).** The oracle exposes `priceInUSD`
(attoUSD) alongside the upstream wei quote; the controller adds
`registerWithUSDG`/`renewWithUSDG`/`rentPriceUSDG`, charging the flat USD
price in USDG (ceil-rounded to token units, `safeTransferFrom`, caller-set
price cap). The upstream ETH paths are behaviourally unchanged; both paths
share one `_register`/`_renew` body. USDG paths emit `USDGPayment` alongside
the standard events. Treasury exit: `withdraw` (ETH) + inherited
`recoverFunds` (ERC-20), both owner-destination.

**Reserved names (controller + new list contract).** `_available` also
requires the label off `RobinReservedList` (owner-updatable, batch setters,
plaintext or hash). Renewals are unaffected by reservation. The list is
seeded inside the deploy broadcast, before the controller is enabled — no
sniping window.

**Rehearsable timers (registrar, wrapper, oracle, controller).** Upstream
constants → immutables so the full lifecycle can be exercised on a live
testnet: `GRACE_PERIOD` (registrar: constructor arg; wrapper: read from the
registrar so they cannot disagree; oracle: constructor arg, deploy-asserted
equal), premium decay length, and `MIN_REGISTRATION_DURATION`. Mainnet
deploys pin all of them to the upstream values (90 days / 21 days / 28 days)
and the deploy script *requires* it. Because immutables are unreadable from
`pure` functions, the duration checks moved from `makeCommitment` to
`_register` — a commitment with a bad duration is accepted but its
registration reverts.

**Duration cap (controller).** `MAX_REGISTRATION_DURATION = 3650 days` per
registration/renewal transaction.

**Renewals via wrapper (controller).** `_renew` calls `wrapper.renew`
(exactly what ENS's wrapped-era controller did) instead of the registrar
directly: for wrapped names the wrapper updates its fuse expiry; for
unwrapped names it passes through. Upstream v1.7.0's direct renewal leaves a
wrapped name's wrapper expiry stale — upstream's own test for this is
skipped ("due to name wrapper complexity"). Operational invariant: the
controller stays a controller on registrar + wrapper, and the wrapper on the
registrar.

**Feed safety (oracle).** `latestRoundData` with revert on non-positive
answer or update older than `maxFeedAge` (mainnet: 36h against the feed's
24h heartbeat), replacing upstream's unchecked, deprecated `latestAnswer`.
A halted feed disables the ETH quote path only; USDG pricing is
oracle-independent. The premium decay math and its bit constants are
verbatim upstream — differential fuzz in
`test-forge/robin/RobinPriceOracle.t.sol` asserts bit-for-bit parity.

**Launch promo (oracle).** `block.timestamp < promoEnd && strlen >= 5` →
base price halved. Premiums never discounted. `promoEnd` immutable
(deploy + 7 days at mainnet).

**Smart-wallet refunds (controller).** `transfer` → OZ `Address.sendValue`
for refunds and `withdraw` (2300-gas stipend bricks Safe/AA wallets — the
norm on this chain). Both run after all state changes; re-entering requires
a fresh commitment and fresh payment.

**Label recording + metadata (registrar + new renderer).** Registrations go
through `registerWithLabel`, storing the plaintext label once per labelhash;
`tokenURI`/`contractURI` delegate to a swappable renderer. `RobinMetadata`
renders JSON + SVG entirely on-chain for both collections (labels from the
registrar, DNS-decoded names from the wrapper), with JSON and XML escaping
of hostile labels, and reports `IERC721Metadata` in `supportsInterface`.
Collection identity: ERC-721 "Robin Names" (ROBIN), ERC-1155 "Robin Wrapped
Names".

## Known accepted behaviours (upstream-inherited)

- `valid()` is length-only; ENSIP-15 normalization is an application-layer
  concern (as in ENS). Hostile labels are escaped in metadata.
- The premium starts at the exact grace-end second, one second before the
  registrar makes the name available (`>` vs `<` boundary, upstream
  semantics).
- Renewal has no minimum duration (upstream semantics); it has the 10-year
  per-transaction cap.
- Registry `owner` of a 2LD node does not follow ERC-721 transfers until
  `reclaim` (upstream semantics).

## Verification

- `forge test` — 80 tests: unit + lifecycle + reentrancy-guard + differential
  fuzz vs upstream oracle/registrar + handler-based invariants (payment
  conservation, reserved-never-registered, expiry bookkeeping).
- `bun run test` — upstream Hardhat/vitest suite, unmodified contracts
  (config timeout raised for slow filesystems).
- `./script/rehearse.sh local all` — deploy + full lifecycle against anvil:
  register (ETH + USDG) → records → primary → UniversalResolver → wrap →
  subdomain → ERC-1155 trade → renew (wrapper sync) → expiry → grace →
  premium purchase → decay-to-zero → re-registration → metadata.
