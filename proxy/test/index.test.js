import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { refresh, buildSnapshot, compactStation, pencePerLitre, isoDate, prettify, extractRecords } from "../src/index.js";

const ENV = { FUEL_FINDER_CLIENT_ID: "id", FUEL_FINDER_CLIENT_SECRET: "secret", APP_KEY: "app-key" };

function memoryKV(initial = {}) {
  const store = new Map(Object.entries(initial));
  return {
    store,
    async get(key, type) {
      const value = store.get(key);
      if (value == null) return null;
      return type === "json" ? JSON.parse(value) : value;
    },
    async put(key, value) { store.set(key, value); },
  };
}

const STATION = {
  node_id: "abc123",
  trading_name: "TESCO EXTRA LEEDS",
  brand_name: "TESCO",
  temporary_closure: false,
  permanent_closure: null,
  location: { address_line_1: "1 HIGH STREET", address_line_2: null, city: "LEEDS", postcode: "ls1 1aa", latitude: "53.8", longitude: -1.55 },
};

const PRICES = {
  node_id: "abc123",
  trading_name: "TESCO EXTRA LEEDS",
  fuel_prices: [
    { fuel_type: "E10", price: 139.9, price_last_updated: "2026-10-08 09:00:00" },
    { fuel_type: "B7_STANDARD", price: 1.459, price_last_updated: "08/10/2026 08:30:00" },
    { fuel_type: "E5", price: 0, price_last_updated: null },
  ],
};

/** A fake Fuel Finder: one page of each resource, then the "no more data" 404. */
function fakeApi({ tokenStatus = 200, wrap = true } = {}) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url, init });
    if (url.endsWith("/api/v1/oauth/generate_access_token")) {
      if (tokenStatus !== 200) return new Response("{}", { status: tokenStatus });
      return Response.json({ success: true, data: { access_token: "tok", token_type: "Bearer", expires_in: 3600 } });
    }
    assert.equal(init.headers.Authorization, "Bearer tok");
    const batch = Number(new URL(url).searchParams.get("batch-number"));
    const records = url.includes("/fuel-prices") ? [PRICES] : [STATION];
    if (batch > 1) return Response.json({ message: "All PFS data have been fetched successfully. No more data available." }, { status: 404 });
    return Response.json(wrap ? { success: true, data: { success: true, data: records } } : records);
  };
  return { fetchImpl, calls };
}

test("refresh builds a trimmed snapshot from the API", async () => {
  const FUEL = memoryKV();
  const { fetchImpl, calls } = fakeApi();
  const snapshot = await refresh({ ...ENV, FUEL }, { fetchImpl, sleep: async () => {} });

  assert.equal(snapshot.stations.length, 1);
  const [station] = snapshot.stations;
  assert.deepEqual(
    { ...station, prices: undefined },
    {
      id: "abc123", name: "Tesco Extra Leeds", brand: "Tesco", address: "1 High Street, Leeds",
      postcode: "LS1 1AA", latitude: 53.8, longitude: -1.55, isClosed: false, prices: undefined,
    },
  );
  assert.deepEqual(station.prices, [
    { fuelType: "E10", pence: 139.9, updated: "2026-10-08T09:00:00.000Z" },
    { fuelType: "B7_STANDARD", pence: 145.9, updated: "2026-10-08T08:30:00.000Z" },
  ]);
  // Raw-only fields must not leak into what the app is served.
  assert.ok(!JSON.stringify(snapshot).includes("node_id"));
  assert.ok(FUEL.store.has("snapshot") && FUEL.store.has("stations"));
  // One token, two pages of each resource, nothing more.
  assert.equal(calls.length, 5);
});

test("station data is reused for an hour", async () => {
  const FUEL = memoryKV();
  const sleep = async () => {};
  let clock = 1_000_000;
  const now = () => clock;

  await refresh({ ...ENV, FUEL }, { fetchImpl: fakeApi().fetchImpl, sleep, now });
  clock += 15 * 60 * 1000;
  const second = fakeApi();
  await refresh({ ...ENV, FUEL }, { fetchImpl: second.fetchImpl, sleep, now });
  assert.ok(second.calls.every((c) => !c.url.includes("/api/v1/pfs?")));

  clock += 60 * 60 * 1000;
  const third = fakeApi();
  await refresh({ ...ENV, FUEL }, { fetchImpl: third.fetchImpl, sleep, now });
  assert.ok(third.calls.some((c) => c.url.includes("/api/v1/pfs?")));
});

test("unwrapped list responses work too", async () => {
  const FUEL = memoryKV();
  const snapshot = await refresh({ ...ENV, FUEL }, { fetchImpl: fakeApi({ wrap: false }).fetchImpl, sleep: async () => {} });
  assert.equal(snapshot.stations.length, 1);
});

test("token falls back to a form post when JSON is refused", async () => {
  const bodies = [];
  const fetchImpl = async (url, init = {}) => {
    if (url.endsWith("/generate_access_token")) {
      bodies.push(init);
      if (init.headers["Content-Type"] === "application/json") return new Response("{}", { status: 415 });
      return Response.json({ access_token: "tok", token_type: "Bearer", expires_in: 3600 });
    }
    return fakeApi().fetchImpl(url, init);
  };
  const FUEL = memoryKV();
  await refresh({ ...ENV, FUEL }, { fetchImpl, sleep: async () => {} });
  assert.equal(bodies.length, 2);
  const form = new URLSearchParams(bodies[1].body);
  assert.equal(form.get("grant_type"), "client_credentials");
  assert.equal(form.get("scope"), "fuelfinder.read");
});

test("bad credentials fail without overwriting the snapshot", async () => {
  const FUEL = memoryKV({ snapshot: '{"stations":[]}' });
  await assert.rejects(
    refresh({ ...ENV, FUEL }, { fetchImpl: fakeApi({ tokenStatus: 401 }).fetchImpl, sleep: async () => {} }),
    /Token request failed: 401/,
  );
  assert.equal(FUEL.store.get("snapshot"), '{"stations":[]}');
});

test("fetch requires the app key and serves the snapshot", async () => {
  const FUEL = memoryKV({ snapshot: '{"stations":[]}' });
  const env = { ...ENV, FUEL };

  const denied = await worker.fetch(new Request("https://x/v1/stations"), env);
  assert.equal(denied.status, 401);

  const ok = await worker.fetch(new Request("https://x/v1/stations", { headers: { "X-App-Key": "app-key" } }), env);
  assert.equal(ok.status, 200);
  assert.equal(await ok.text(), '{"stations":[]}');

  const missing = await worker.fetch(new Request("https://x/other", { headers: { "X-App-Key": "app-key" } }), env);
  assert.equal(missing.status, 404);
});

test("helpers", () => {
  assert.equal(pencePerLitre(139.9), 139.9);
  assert.equal(pencePerLitre(1.399), 139.9);
  assert.equal(pencePerLitre(1399), 139.9);
  assert.equal(pencePerLitre(0), null);
  assert.equal(pencePerLitre(9999), null);

  assert.equal(isoDate("2026-10-08T09:00:00+01:00"), "2026-10-08T08:00:00.000Z");
  assert.equal(isoDate("nonsense"), null);

  assert.equal(prettify("BP"), "BP");
  assert.equal(prettify("SHELL MFG"), "Shell Mfg");
  assert.equal(prettify("Already Nice"), "Already Nice");

  assert.deepEqual(extractRecords({ data: { data: [1] } }), [1]);
  assert.equal(compactStation({ node_id: 1, location: { latitude: 0, longitude: 0 } }), null);

  const newerWins = buildSnapshot(
    [compactStation(STATION)],
    [
      { node_id: "abc123", fuel_prices: [{ fuel_type: "E10", price: 140, price_last_updated: "2026-10-08T10:00:00Z" }] },
      { node_id: "abc123", fuel_prices: [{ fuel_type: "E10", price: 130, price_last_updated: "2026-10-01T10:00:00Z" }] },
    ],
    new Date(0),
  );
  assert.equal(newerWins.stations[0].prices[0].pence, 140);
});
