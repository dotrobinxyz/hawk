# Robin indexer

Ponder app indexing the complete Robin naming state on Robinhood Chain:
registrations and renewals (with payment currency and revenue), 721/1155
ownership, wraps and fuses, subnames, resolver records, primary names, and
the reserved list. Serves GraphQL at `/graphql` and SQL-over-HTTP at `/sql`.

```bash
npm install
node scripts/sync-abis.mjs        # ABIs from ../contracts/out
ROBIN_NETWORK=robinhood-testnet npm run dev
```

- `ROBIN_NETWORK` ∈ `local` | `robinhood-testnet` | `robinhood` — addresses
  load from `../contracts/deployments/robin-<network>.json`
  (override the file with `DEPLOYMENT_FILE`).
- `START_BLOCK` — set to the deployment block on live networks.
- Production: set `DATABASE_URL` (Postgres) and run
  `DATABASE_SCHEMA=robin npm start`. Dev uses embedded PGlite.
- WSL note: run from a native-filesystem checkout (or set `PGLITE_DIR`
  off `/mnt/*`) — Windows-mounted paths stall the dev server badly.
