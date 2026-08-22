import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { client, graphql } from "ponder";

const app = new Hono();

// SQL-over-HTTP for @ponder/client consumers.
app.use("/sql/*", client({ db, schema }));

// GraphQL at / and /graphql.
app.use("/", graphql({ db, schema }));
app.use("/graphql", graphql({ db, schema }));

export default app;
