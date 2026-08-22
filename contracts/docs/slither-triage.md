# Slither triage — contracts/robin/

Run: `slither contracts/robin/ --foundry-out-directory out` (60 results,
informational/optimization excluded; upstream directories filtered — upstream
code is audited separately by eight years of ENS review). Every finding below
is **triaged-accepted**; none are actionable. Re-run before freeze and diff
against this list.

## High (2) — both upstream-verbatim false positives

| Finding | Location | Triage |
|---|---|---|
| `encode-packed-collision` | `RobinWrapper._addLabel` | Upstream NameWrapper DNS-name construction. Inputs are length-prefixed wire format by design — no ambiguity. Verbatim upstream; covered by upstream audits + our wrapper tests. |
| `arbitrary-send-erc20` | `RobinWrapper.wrapETH2LD` | `registrar.transferFrom(registrant, this, id)` is guarded three lines above (`msg.sender == registrant \|\| isApprovedForAll`). Verbatim upstream. |

## Medium (28)

| Finding | Location | Triage |
|---|---|---|
| `divide-before-multiply` ×16 | `RobinPriceOracle.decayedPremium` / `addFractionalPremium` | Upstream's exact fixed-point premium-decay math and bit constants. Differential fuzz (`testFuzz_premiumMatchesUpstream`) asserts bit-for-bit parity with the deployed upstream oracle. Intentional. |
| `divide-before-multiply` ×4 | `RobinMetadata._dateString` | Hinnant days-from-civil integer algorithm — division order is the algorithm. Vector-tested incl. leap day and year boundaries. |
| `unused-return` ×6 | controller `_register` (resolver multicall, reverse setters), registrar `_register`/`reclaim` (`ens.setSubnodeOwner`), wrapper `setSubnodeOwner`, oracle `_ethPrice` (partial `latestRoundData` destructure), metadata `uri` | All explicit discards, matching upstream call-sites; return values carry no decision-relevant information at these sites. |
| `uninitialized-local` | `RobinMetadata.uri` (`badge`) | Deliberate empty-string default, branch-assigned, checked via `bytes(badge).length`. |
| `reentrancy-no-eth` | `RobinWrapper.setUpgradeContract` | Owner-only migration hook, verbatim upstream. |

## Low (30)

- `timestamp` ×20 — expiries, grace, commit-reveal ages, premium decay, and
  promo windows are *the product*; all comparisons operate at day/hour
  granularity where sequencer timestamp skew (seconds) is immaterial. Same
  profile as upstream ENS.
- `reentrancy-events` ×7 / `reentrancy-benign` ×1 — events emitted after
  external calls (upstream pattern), and the USDG paths emit `USDGPayment`
  after `safeTransferFrom` by design (payment precedes effects; `_register`
  still enforces commitment + availability, so re-entry needs a fresh
  commitment and fresh payment; USDG/ERC-20 has no transfer hooks).
- `registerWithLabel` label write after `_register` — atomic within the
  transaction; ordering is cosmetic.

## Robin-specific hardening beyond upstream

For the reviewer's orientation, the fork *adds* checks upstream lacks:
checked `latestRoundData` with staleness bounds (vs deprecated unchecked
`latestAnswer`), `sendValue` refunds (vs `transfer`), caller price caps on
the USDG paths, and wrapper-synced renewals.
