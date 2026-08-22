// Live-resolution smoke test: stock viem ENS actions against a local Robin
// deployment (deploy + rehearse stage1 must have run against anvil first):
//   cd contracts && ROBIN_NETWORK=local forge script ... && REHEARSAL_LABEL=smoketest ./script/rehearse.sh local stage1
// then: node --test test/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createPublicClient, defineChain, http } from "viem";
import { withRobin, robinAddressesFrom, getRobinName, getRobinAddress, getRobinText } from "../dist/index.js";

const deployment = JSON.parse(
  readFileSync(new URL("../../../contracts/deployments/robin-local.json", import.meta.url)),
);
const addresses = robinAddressesFrom(deployment);

const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});

const client = createPublicClient({
  chain: withRobin(anvil, addresses),
  transport: http(),
});

// anvil account #0 — registered smoketest.robin with a primary name
const OWNER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

test("forward resolution via stock viem getEnsAddress", async () => {
  const address = await client.getEnsAddress({ name: "smoketest.robin" });
  assert.equal(address, OWNER);
});

test("reverse resolution via stock viem getEnsName", async () => {
  const name = await client.getEnsName({ address: OWNER });
  assert.equal(name, "smoketest.robin");
});

test("text records via stock viem getEnsText", async () => {
  const url = await client.getEnsText({ name: "smoketest.robin", key: "url" });
  assert.equal(url, "https://example.invalid");
});

test("SDK wrappers agree", async () => {
  assert.equal(await getRobinAddress(client, { name: "smoketest.robin" }), OWNER);
  assert.equal(await getRobinName(client, { address: OWNER }), "smoketest.robin");
  assert.equal(
    await getRobinText(client, { name: "smoketest.robin", key: "url" }),
    "https://example.invalid",
  );
});

test("unregistered names resolve to null", async () => {
  assert.equal(await client.getEnsAddress({ name: "no-such-name-xyz.robin" }), null);
});
