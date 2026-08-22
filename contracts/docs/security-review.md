# Robin — adversarial security review

Scope: `contracts/robin/` and `script/` only; upstream ens-contracts (v1.7.0)
treated as trusted. Method: red-team review of the delta against upstream,
grounded against the live testnet bytecode (chainId 46630). Read
[`audit-surface.md`](./audit-surface.md) for the full diff inventory.

**Verdict: no critical or high-severity findings.** Fund-handling and
reserved-name invariants hold in the code and on-chain. One low-severity
deploy-ordering issue (fixed — see status) and three informational items.

## Findings

### LOW‑1 — Reserved list seeded after the controller goes live (FIXED)

`script/DeployRobin.s.sol` originally ran `registrar.addController(controller)`
(inside `_deployControllerAndResolvers`) **before** `_seedReservations()`. The
testnet broadcast showed the controller authorized as a registrar controller
at tx #17 but reservations not seeded until tx #25–27 — an eight-transaction
window in which every reserved ticker was registerable.

Exploitability was Low: a sniper needed a commit‑reveal commitment already
matured (`minCommitmentAge` = 60s) at the instant the controller went live and
a `register("nvda")` landing inside that window. On an FCFS Orbit chain with
sequential deployer nonces the window is a few seconds — under 60s — so it was
not practically exploitable as configured. But the safety rested on commit
timing rather than on the ordering the docs claimed, and would have opened if
`minCommitmentAge` were lowered or block production stalled mid-deploy.

**Status: FIXED.** `_seedReservations()` now runs immediately after
`_deployCore()` (which deploys the reserved list) and before the controller is
constructed or enabled. At that point no public registration path exists — the
only registrar controller is the wrapper, whose sole registration entrypoint is
itself `onlyController` on a wrapper that has no controllers yet — so
reservations are fully in place before the controller can ever register a name.
Verified on a fresh local deploy: `setReserved` now precedes the controller's
`addController` in the broadcast.

### INFO‑1 — Reserved enforcement is controller-only (documented as an invariant)

`RobinReservedList` is consulted only in `RobinRegistrarController._available`.
`RobinBaseRegistrar.register/registerWithLabel` and
`RobinWrapper.registerAndWrapETH2LD` can mint `.robin` 2LDs with no reserved
check, gated only by `onlyController`. Not attacker-reachable today (the only
registrar controllers are the Robin controller and the wrapper; the wrapper's
registration entrypoint is `onlyController` and never invoked by the Robin
controller — verified on-chain). The latent risk is that any *future*
registrar/wrapper controller must re-implement the reserved check. Recorded as
a standing invariant in [`../../ops/runbook.md`](../../ops/runbook.md).

### INFO‑2 — `transfer` → `sendValue` removes the reentrancy gas-guard (hardened)

ETH refunds and `withdraw()` forward all gas (deliberate, for smart-wallet
compatibility), so a contract caller can reenter. No profitable reentrancy was
found: refunds are computed and fixed before the external call and paid once;
reentering `register`/`renew` needs fresh payment and fails the availability
gate for the same name; `withdraw()` only ever pays `owner()`. As cheap
defense-in-depth, `nonReentrant` (OZ `ReentrancyGuard`) was added to the four
register/renew entrypoints (`register`, `registerWithUSDG`, `renew`,
`renewWithUSDG`). `withdraw()` is intentionally left unguarded (owner-only
sink).

### INFO‑3 — MockUSDG has an open `mint()`

Testnet/local only; the mainnet config forbids `usdg == address(0)`, so the mock
is never deployed on mainnet. Correct for a faucet token. Noted for
completeness.

## Attacked and could not break

- **Fund theft** — controller ETH exits only via `withdraw()`→owner; USDG only
  via `recoverFunds`→onlyOwner. Refunds bounded to the payer's own overpayment;
  no arbitrary-recipient sink. Underpayment blocked; USDG conversion uses
  `Math.ceilDiv` (rounds toward the protocol). No free registration at any
  length, duration, or promo state.
- **Payment atomicity** — USDG `safeTransferFrom` precedes `_register`; a
  registration revert rolls the transfer back. No orphaned payments.
- **Reserved-name creation via any path** — `register` blocked by `_available`;
  `renew` cannot create a name (registrar.renew reverts for a never-registered
  label past its zero-expiry grace); direct registrar/wrapper mints are
  `onlyController` with no public un-gated entrypoint.
- **Expiry/premium math** — verbatim upstream (fuzz-parity tested); only grace
  and decay-window became immutables, deploy-asserted equal to the registrar's
  grace and confirmed on-chain. `endValue` subtraction underflow-guarded;
  never-registered names price to premium 0.
- **Feed manipulation / DoS** — stale/non-positive answers revert ETH quoting
  only; the USDG path never reads the feed, so an outage degrades to USDG-only
  rather than halting registration.
- **Duration-check relocation** — moving bounds from the `pure makeCommitment`
  into `_register` is safe: `_register` re-derives the commitment and checks
  duration before minting.
- **Renew-through-wrapper** — no external callback to attacker; trusted-contract
  calls only; wrapped expiry updated upward without desync; unwrapped names pass
  through.
- **Wrapper griefing / metadata** — wrapper diff is exactly TLD constants +
  immutable grace + collection name. `RobinMetadata` is strictly view-only and
  on no state-changing path, so a hostile label or reverting renderer at most
  breaks one token's marketplace display; labels are JSON/XML-escaped.

## On-chain confirmation (testnet 46630)

Reserved gate active (`available("nvda"/"hood"/"robinhood") == false`);
registrar controller set is exactly `{controller, wrapper}`, with deployer and
arbitrary addresses holding no controller rights; `oracle.GRACE_PERIOD ==
registrar.GRACE_PERIOD`; `registry.owner(namehash("robin")) == registrar`.
