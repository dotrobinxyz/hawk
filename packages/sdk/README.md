# robin-names

Resolve and register `.robin` names on Robinhood Chain — ENS-standard
resolution with a one-line viem config.

Robin implements the exact ENS interfaces (ERC-137 registry, standard
resolver profiles, ENSIP namehash, reverse records, a UniversalResolver), so
**the ENS tooling you already use works unchanged** — stock viem, wagmi, and
ethers resolve `.robin` once they know where the registry lives.

## Install

```sh
npm i robin-names viem
```

## Use

```ts
import { createPublicClient, http } from "viem";
import { robinhoodChainTestnet } from "robin-names"; // ← the one line

const client = createPublicClient({
  chain: robinhoodChainTestnet,
  transport: http(),
});

// reverse: address → name (render this instead of 0x…)
await client.getEnsName({ address: "0x71C7656EC7ab88b098defB751B7401B5f6d8976F" });

// forward: name → address (payments, transfers, search)
await client.getEnsAddress({ name: "trader.robin" });

// profile records
await client.getEnsText({ name: "trader.robin", key: "com.twitter" });
await client.getEnsAvatar({ name: "trader.robin" });
```

With wagmi, pass the chain into your config and use the stock hooks —
`useEnsName`, `useEnsAddress`, `useEnsText`, `useEnsAvatar`. Nothing else
changes. Already have your own chain object? Wrap it:
`withRobin(myChainConfig)`.

Live today on Robinhood Chain testnet (chainId 46630). Robin on mainnet
(chainId 4663) is not yet deployed; `robinhoodChain` ships ready for it, and
addresses always come from the deploy script's own record in
[`contracts/deployments/`](https://github.com/dotrobinxyz/robin/tree/main/contracts/deployments).

## Also exported

- `ROBIN_ADDRESSES`, `getRobinAddresses` — the verified contract addresses
- `getRobinName` / `getRobinAddress` / `getRobinText` / `getRobinAvatar` —
  standalone actions when you don't want to touch your chain object
- `makeRegistration`, `makeCommitment`, `randomSecret`, `validateLabel` —
  commit–reveal registration helpers
- `normalize`, `namehash`, `labelhash` (re-exported from `viem/ens`) — always
  normalize user input before hashing
- Typed ABIs for every deployed contract

## More

- Docs: <https://docs.dotrobin.xyz>
- App: <https://dotrobin.xyz>
- Indexed data (GraphQL, CORS open): <https://api.dotrobin.xyz/graphql>
- Source: [github.com/dotrobinxyz/robin](https://github.com/dotrobinxyz/robin) — `packages/sdk`

MIT © dotrobinxyz
