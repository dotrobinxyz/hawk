# Robin contracts

The contracts behind **Robin — names on Robinhood Chain** (chainId 4663):
`trader.robin` with ENS-standard resolution, annual renewals, tradeable
wrapped subnames, and expiry premium auctions.

This repository is a fork of
[`ensdomains/ens-contracts`](https://github.com/ensdomains/ens-contracts)
pinned at **v1.7.0**. Every upstream file is byte-identical to the tag; all
Robin work is additive under [`contracts/robin/`](./contracts/robin), which
keeps the audit surface small and mechanically checkable:

- `./script/diff-upstream.sh` — prints the complete delta vs upstream
- each file under `contracts/robin/` documents its own diffs in a header comment

## The deployed set

| Contract | Role |
|---|---|
| `RobinRegistry` | ERC-137 registry — `namehash → owner, resolver, ttl` |
| `RobinBaseRegistrar` | `.robin` second-level names as ERC-721 "Robin Names" (ROBIN), 90-day grace |
| `RobinRegistrarController` | Commit-reveal registration + renewal; pay in USDG (flat USD) or ETH (Chainlink) |
| `RobinPriceOracle` | $100/$25/$5 per year by length; launch promo; $1,000 → $0 exponential expiry premium over 21 days |
| `RobinWrapper` | ERC-1155 wrapping, fuses, tradeable subnames ("Robin Wrapped Names") |
| `RobinMetadata` | Fully on-chain SVG + JSON metadata for both collections |
| `RobinReservedList` | Owner-updatable blocklist (stock tickers, brands, abuse terms) |
| `PublicResolver`, `ReverseRegistrar`, `DefaultReverseRegistrar`, `UniversalResolver` | Upstream, zero diff |

## Build & test

```bash
npm install -g bun && bun install       # upstream toolchain deps
forge build                             # foundry is the primary toolchain
forge test                              # Robin suite: unit + differential fuzz + invariants
bun run test                            # upstream Hardhat/vitest suite (unmodified contracts)
```

## Deploy & rehearse

```bash
# local, end to end
anvil &
ROBIN_NETWORK=local forge script script/DeployRobin.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil-key>
./script/rehearse.sh local all          # register → wrap → subnames → trade →
                                        # renew → expiry → grace → premium
                                        # auction → decay → re-registration

# testnet (shortened timers; see script/config/robinhood-testnet.json)
ROBIN_NETWORK=robinhood-testnet forge script script/DeployRobin.s.sol \
  --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast \
  --private-key $ROBIN_PK --verify --verifier blockscout \
  --verifier-url https://explorer.testnet.chain.robinhood.com/api
```

Mainnet deployment additionally requires `finalOwner` (the multisig) set in
`script/config/robinhood.json` — the script refuses to run without it — and
pins grace/premium/min-duration to the canonical 90d/21d/28d values.

## License

MIT, as upstream. Upstream code © ENS Labs and contributors; Robin
additions © dotrobinxyz.
