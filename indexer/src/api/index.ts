import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { client, graphql } from "ponder";
import { agentApi } from "./agents";

const app = new Hono();

// Agent identity API (/verify, /agents) — dark-launched. The routes exist
// only when HAWK_AGENT_API=1 is set in the service environment; without it
// every path 404s exactly as before the feature existed. CORS is handled at
// the Caddy layer (api.dothawk.xyz adds Access-Control-Allow-Origin on every
// response), so no middleware here.
if (process.env.HAWK_AGENT_API === "1") {
  app.route("/", agentApi);
}

// SQL-over-HTTP for @ponder/client consumers.
app.use("/sql/*", client({ db, schema }));

// GraphQL at / and /graphql.
app.use("/", graphql({ db, schema }));
app.use("/graphql", graphql({ db, schema }));

export default app;
