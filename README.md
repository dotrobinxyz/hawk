# Hawk

Hawk is ENS-standard naming for Base (chainId 8453), built for the agent
economy: human-readable `.hawk` names for wallets, bots, and agent fleets,
with annual renewals, standards-compliant resolution, tradeable wrapped
subnames, fully on-chain SVG metadata, and expiry auctions. The contracts
are a minimal-diff fork of
[ens-contracts](https://github.com/ensdomains/ens-contracts); any ENS-aware
library resolves `.hawk` by pointing at the registry and UniversalResolver.

Agents fly under their operator's name — `bot1.bankr.hawk` cryptographically
hangs off `bankr.hawk`: verifiable delegation, machine-readable capability
records, revocable or tradeable as real tokens.

## Repository

- `contracts/` — the Hawk contracts (fork of ens-contracts) + Foundry tests
- `packages/sdk/` — `hawk-names`, one-line viem/wagmi resolution
- `indexer/` — Ponder indexer (GraphQL) for names, records, and auctions
- `apps/web/` — the web app (search, register, manage, renew, subnames)

## Deployments

Not yet deployed — Base Sepolia rehearsal first, then Base mainnet.
Addresses will land in `contracts/deployments/` (the deploy script's own
record, so published addresses can never drift from what's on chain).

## License

MIT — see [LICENSE](./LICENSE). Contracts include code from
ensdomains/ens-contracts (© ENS Labs Ltd, MIT).
Security: [SECURITY.md](./SECURITY.md).
