// Fill Me Up proxy — a Cloudflare Worker.
//
// Fuel Finder's terms say OAuth client secrets must stay on a backend and
// raw API data must not be redistributed. So this worker:
//   * holds the client ID/secret as Worker secrets,
//   * refreshes from the Fuel Finder API on a cron (stations hourly, prices
//     every 15 minutes, as the developer guidelines recommend),
//   * stores a trimmed, app-specific snapshot in KV,
//   * serves it to the app at GET /v1/stations, gated by an app key.
//
// One cron run makes ~35 API requests, well inside 100/minute, one at a time.

const LIVE_HOST = "www.fuel-finder.service.gov.uk";
const REQUEST_GAP_MS = 750;
const STATIONS_TTL_MS = 60 * 60 * 1000;
const MAX_BATCHES = 100;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/v1/stations") return json({ message: "Not found" }, 404);
    if (request.method !== "GET") return json({ message: "Method not allowed" }, 405);
    if (env.APP_KEY && request.headers.get("X-App-Key") !== env.APP_KEY) {
      return json({ message: "Unauthorised" }, 401);
    }

    const snapshot = await env.FUEL.get("snapshot");
    if (!snapshot) return json({ message: "Prices are still loading. Try again in a few minutes." }, 503);
    return new Response(snapshot, {
      headers: { "Content-Type": "application/json", "Cache-Control": "private, max-age=300" },
    });
  },

  async scheduled(_event, env, ctx) {
    ctx.waitUntil(refresh(env));
  },
};

/** Pulls fresh data from Fuel Finder and rewrites the snapshot. */
export async function refresh(env, { fetchImpl = fetch, sleep = defaultSleep, now = Date.now } = {}) {
  const api = new FuelFinderApi(env, fetchImpl, sleep);

  let stations = await env.FUEL.get("stations", "json");
  if (!stations || now() - stations.fetchedAt > STATIONS_TTL_MS) {
    const records = (await api.allPages("/api/v1/pfs")).map(compactStation).filter(Boolean);
    // An empty list is an upstream fault; keep serving what we had.
    if (records.length > 0) {
      stations = { fetchedAt: now(), records };
      await env.FUEL.put("stations", JSON.stringify(stations));
    }
  }
  if (!stations) throw new Error("No station data available yet");

  const priceRows = await api.allPages("/api/v1/pfs/fuel-prices");
  if (priceRows.length === 0) throw new Error("Fuel Finder returned no prices");

  const snapshot = buildSnapshot(stations.records, priceRows, new Date(now()));
  await env.FUEL.put("snapshot", JSON.stringify(snapshot));
  return snapshot;
}

// ---------------------------------------------------------------------------
// Fuel Finder API client

export class FuelFinderApi {
  constructor(env, fetchImpl = fetch, sleep = defaultSleep) {
    if (!env.FUEL_FINDER_CLIENT_ID || !env.FUEL_FINDER_CLIENT_SECRET) {
      throw new Error("FUEL_FINDER_CLIENT_ID and FUEL_FINDER_CLIENT_SECRET must be set");
    }
    this.env = env;
    this.baseUrl = `https://${env.FUEL_FINDER_API_HOST || LIVE_HOST}`;
    this.fetch = fetchImpl;
    this.sleep = sleep;
    this.token = null;
    this.lastRequestAt = 0;
  }

  async allPages(path) {
    const records = [];
    let previousBody = null;
    for (let batch = 1; batch <= MAX_BATCHES; batch++) {
      const response = await this.get(`${path}?batch-number=${batch}`);
      const body = await response.text();
      if (!response.ok) {
        // The API ends paging with a 404 or a "no more data" message.
        if (/no more data/i.test(body) || (response.status === 404 && batch > 1)) break;
        throw new Error(`GET ${path} batch ${batch} failed: ${response.status} ${body.slice(0, 200)}`);
      }
      if (body === previousBody) break;
      previousBody = body;

      const page = extractRecords(JSON.parse(body));
      if (!page || page.length === 0) break;
      records.push(...page);
    }
    return records;
  }

  async get(pathAndQuery) {
    let retriedAuth = false;
    for (let rateLimitRetries = 0; ; ) {
      const token = await this.accessToken();
      const response = await this.send(this.baseUrl + pathAndQuery, {
        headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      });
      if ((response.status === 401 || response.status === 403) && !retriedAuth) {
        retriedAuth = true;
        this.token = null;
        continue;
      }
      if (response.status === 429 && rateLimitRetries < 4) {
        const retryAfter = Number(response.headers.get("Retry-After"));
        const delay = Math.min(retryAfter > 0 ? retryAfter : 5 * 2 ** rateLimitRetries, 60);
        rateLimitRetries++;
        await this.sleep(delay * 1000);
        continue;
      }
      return response;
    }
  }

  async accessToken() {
    if (this.token && this.token.expiresAt > Date.now()) return this.token.value;

    const url = `${this.baseUrl}/api/v1/oauth/generate_access_token`;
    const credentials = {
      client_id: this.env.FUEL_FINDER_CLIENT_ID,
      client_secret: this.env.FUEL_FINDER_CLIENT_SECRET,
    };
    // The live service takes JSON; the portal documents a standard OAuth form
    // post with a grant type and scope. Try one, then the other.
    let response = await this.send(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(credentials),
    });
    if ([400, 415, 422].includes(response.status)) {
      response = await this.send(url, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
        body: new URLSearchParams({ grant_type: "client_credentials", scope: "fuelfinder.read", ...credentials }).toString(),
      });
    }
    const body = await response.json().catch(() => ({}));
    const data = body && typeof body.data === "object" && body.data ? body.data : body;
    if (!response.ok || typeof data.access_token !== "string") {
      // Never log the request: it carries the client secret.
      throw new Error(`Token request failed: ${response.status} ${body.message || ""}`.trim());
    }
    const lifetime = Math.max(Number(data.expires_in) || 3600, 120) - 60;
    this.token = { value: data.access_token, expiresAt: Date.now() + lifetime * 1000 };
    return this.token.value;
  }

  /** One request at a time, spaced to stay under 100 a minute. */
  async send(url, init) {
    const wait = this.lastRequestAt + REQUEST_GAP_MS - Date.now();
    if (wait > 0) await this.sleep(wait);
    this.lastRequestAt = Date.now();
    return this.fetch(url, init);
  }
}

// ---------------------------------------------------------------------------
// Transforming API records into the app's format

/** Finds the record list whether the API sent `[...]`, `{data: [...]}` or `{data: {data: [...]}}`. */
export function extractRecords(payload) {
  if (Array.isArray(payload)) return payload;
  if (payload && typeof payload === "object") {
    for (const key of ["data", "results", "items", "records"]) {
      if (key in payload) {
        const nested = extractRecords(payload[key]);
        if (nested) return nested;
      }
    }
  }
  return null;
}

export function compactStation(record) {
  if (!record || record.node_id == null) return null;
  const location = record.location || {};
  const latitude = toNumber(location.latitude);
  const longitude = toNumber(location.longitude);
  if (latitude == null || longitude == null || (latitude === 0 && longitude === 0)) return null;
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;

  const tradingName = text(record.trading_name);
  const brandName = text(record.brand_name);
  return {
    id: String(record.node_id),
    name: prettify(tradingName || brandName || "Fuel station"),
    brand: brandName ? prettify(brandName) : null,
    address: [location.address_line_1, location.address_line_2, location.city]
      .map(text).filter(Boolean).map(prettify).join(", "),
    postcode: text(location.postcode)?.toUpperCase() ?? null,
    latitude,
    longitude,
    isClosed: toBool(record.temporary_closure) || toBool(record.permanent_closure),
  };
}

export function buildSnapshot(stations, priceRows, generatedAt) {
  const pricesById = new Map();
  for (const row of priceRows) {
    if (!row || row.node_id == null || !Array.isArray(row.fuel_prices)) continue;
    const id = String(row.node_id);
    const byFuel = pricesById.get(id) || new Map();
    for (const entry of row.fuel_prices) {
      const fuelType = text(entry?.fuel_type);
      const pence = pencePerLitre(toNumber(entry?.price));
      if (!fuelType || pence == null) continue;
      const updated = isoDate(entry.price_last_updated ?? entry.price_change_effective_timestamp);
      const existing = byFuel.get(fuelType);
      if (existing && existing.updated && updated && updated < existing.updated) continue;
      byFuel.set(fuelType, { fuelType, pence, updated });
    }
    pricesById.set(id, byFuel);
  }

  const out = [];
  for (const station of stations) {
    const prices = [...(pricesById.get(station.id)?.values() ?? [])];
    if (prices.length > 0) out.push({ ...station, prices });
  }
  return { generated_at: generatedAt.toISOString(), stations: out };
}

/** Pence per litre, whether the feed sent pence, pounds or tenths of a penny. */
export function pencePerLitre(raw) {
  if (raw == null) return null;
  let value = raw;
  if (value < 10) value *= 100;
  else if (value >= 1000) value /= 10;
  if (value < 50 || value > 500) return null;
  return Math.round(value * 10) / 10;
}

/** ISO 8601 from the formats the feed uses; zoneless times are UTC. */
export function isoDate(value) {
  const raw = text(value);
  if (!raw) return null;
  let normalised = raw;
  const uk = raw.match(/^(\d{2})\/(\d{2})\/(\d{4})[ T](\d{2}):(\d{2})(?::(\d{2}))?/);
  if (uk) normalised = `${uk[3]}-${uk[2]}-${uk[1]}T${uk[4]}:${uk[5]}:${uk[6] || "00"}`;
  else normalised = raw.replace(" ", "T");
  if (!/(Z|[+-]\d{2}:?\d{2})$/i.test(normalised)) normalised += "Z";
  const date = new Date(normalised);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

/** "TESCO EXTRA" → "Tesco Extra", leaving short acronyms like "BP" alone. */
export function prettify(value) {
  if (value !== value.toUpperCase() || !/[A-Za-z]/.test(value)) return value;
  return value.split(" ").map((word) => {
    if (word.replace(/[^A-Za-z]/g, "").length <= 2) return word;
    return word[0] + word.slice(1).toLowerCase();
  }).join(" ");
}

function text(value) {
  if (value == null) return null;
  const trimmed = String(value).trim();
  return trimmed === "" ? null : trimmed;
}

function toNumber(value) {
  if (value == null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function toBool(value) {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0;
  return ["true", "yes", "y", "1"].includes(String(value ?? "").toLowerCase());
}

function json(body, status) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function defaultSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
