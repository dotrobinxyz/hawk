# hawk-names

Resolve and register `.hawk` names on Base — ENS-standard resolution with a
one-line viem config, built for the agent economy.

Hawk implements the exact ENS interfaces (ERC-137 registry, standard
resolver profiles, ENSIP namehash, reverse records, a UniversalResolver), so
**the ENS tooling you already use works unchanged** — stock viem, wagmi, and
ethers resolve `.hawk` once they know where the registry lives.

## Install

```sh
npm i hawk-names viem
```

## Use

```ts
import { createPublicClient, http } from "viem";
import { base } from "hawk-names"; // ← Base with Hawk wired in as its ENS

const client = createPublicClient({ chain: base, transport: http() });

// reverse: address → name (render this instead of 0x…)
await client.getEnsName({ address: "0x882220CF716aEF2421b6ab283E63427D81497d8c" });
// → "genesis.hawk"

// forward: name → address (payments, transfers, search)
await client.getEnsAddress({ name: "genesis.hawk" });

// profile records
await client.getEnsText({ name: "genesis.hawk", key: "url" });
await client.getEnsAvatar({ name: "genesis.hawk" });
```

With wagmi, pass the chain into your config and use the stock hooks —
`useEnsName`, `useEnsAddress`, `useEnsText`, `useEnsAvatar`. Nothing else
changes. Already have your own Base chain object? Wrap it:
`withHawk(myChainConfig)`.

## Agents

Hawk is agent identity: one parent name per operator, one subname per agent
— `bot1.bankr.hawk` cryptographically hangs off `bankr.hawk`. Subnames are
real ERC-1155 tokens (transferable, revocable), and text records are the
agent's machine-readable capability card (`url`, `agent.capabilities`,
`agent.operator`, …).

## Also exported

- `HAWK_ADDRESSES`, `getHawkAddresses` — the deployed contract addresses
- `getHawkName` / `getHawkAddress` / `getHawkText` / `getHawkAvatar` —
  standalone actions when you don't want to touch your chain object
- `makeRegistration`, `makeCommitment`, `randomSecret`, `validateLabel` —
  commit–reveal registration helpers
- `normalize`, `namehash`, `labelhash` (re-exported from `viem/ens`)
- Typed ABIs for every deployed contract

## More

- App: <https://dothawk.xyz>
- Source: [github.com/dotrobinxyz/hawk](https://github.com/dotrobinxyz/hawk) — `packages/sdk`
- Deployed addresses: `contracts/deployments/hawk-base.json` in the repo

MIT © dotrobinxyz
