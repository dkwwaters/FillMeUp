# Fill Me Up

The cheapest fuel near you, on iPhone and CarPlay, from the UK Government's
[Fuel Finder](https://www.developer.fuel-finder.service.gov.uk) price data.

You grant location access, pick a fuel and a distance, and get a list
sorted cheapest first. Tap a station to get directions in Apple Maps, Google
Maps or Waze. That's all it does.

```
.
├── FillMeUp.xcodeproj
├── Config/          build settings, Info.plist, CarPlay entitlement
├── FillMeUp/        the iOS app (Swift / SwiftUI, iOS 17+)
│   ├── CarPlay/     CarPlay list screen
│   ├── Models/      Station, FuelPrice, FuelType
│   ├── Services/    Fuel Finder client, proxy client, on-device cache, location
│   ├── ViewModels/  FuelModel — shared by the phone and CarPlay
│   └── Views/       the single list screen + welcome / permission screens
└── proxy/           Cloudflare Worker that holds the API credentials
```

## How the data flows

The Fuel Finder API has no "near me" search. It only offers the full list of
~8,000 UK forecourts, paged 500 at a time, rate-limited to 100 requests a
minute. Its terms also say the OAuth **client secret must never be in a mobile
app**, and **raw API data must not be redistributed**.

So shipped builds work like this:

```
Fuel Finder API ──(cron, every 15 min)──▶ proxy (Cloudflare Worker + KV)
                                              │  trimmed, app-only format
                                              ▼
                                   app: GET /v1/stations  (one request)
                                              │
                         filter by distance + sort by price on the phone
```

The app caches the snapshot and checks for new prices at most every 15 minutes.

Debug builds can also call the API **directly** with your client ID and secret,
so you can try the app on your own phone before the proxy is up. Release builds
ignore direct credentials entirely.

## Run it on your phone (Debug, direct to the API)

1. `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig`
2. In `Config/Secrets.xcconfig`, fill in `FUEL_FINDER_CLIENT_ID` and
   `FUEL_FINDER_CLIENT_SECRET` from the developer portal. This file is gitignored.
   - If your keys are **test-environment** keys, also set `FUEL_FINDER_API_HOST`
     to the test service's host name (no `https://`). Leave it empty for live.
3. Open `FillMeUp.xcodeproj`, pick your iPhone, and press ⌘R.

The first launch downloads every station (about 35 requests, ~30 seconds).
After that it only fetches changes.

## Deploy the proxy (needed before App Store release)

You need a Cloudflare account. The **Workers Paid plan ($5/month)** is
recommended: parsing the full UK dataset takes more CPU time than the free
plan's 10 ms per run.

```sh
cd proxy
npm install
npx wrangler login
npx wrangler kv namespace create FUEL        # paste the id into wrangler.toml
npx wrangler secret put FUEL_FINDER_CLIENT_ID
npx wrangler secret put FUEL_FINDER_CLIENT_SECRET
npx wrangler secret put APP_KEY              # any long random string
npm run deploy
```

The cron fills the snapshot within 15 minutes of deploying. Check it with:

```sh
curl -H "X-App-Key: <your APP_KEY>" https://fill-me-up-proxy.<you>.workers.dev/v1/stations | head -c 500
```

Then in `Config/Secrets.xcconfig` set `FILL_ME_UP_API_HOST` (host only, no
`https://`) and `FILL_ME_UP_API_KEY`, and remove the direct credentials.

Run the proxy's tests with `npm test`.

## CarPlay

The app uses CarPlay's **Fueling** category: the same cheapest-first list,
with buttons to cycle the fuel type and distance. Tapping a station starts
directions in whichever maps app you last chose on the phone.

CarPlay needs a special permission (entitlement) from Apple:

1. Request it at <https://developer.apple.com/contact/carplay/> and choose
   **Fueling**. Approval can take a while, so request it now.
2. Until it's approved, the entitlement is only applied to **Simulator** builds
   (`CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]`), so device builds still
   sign. Test in the Simulator with **I/O → External Displays → CarPlay**.
3. Once Apple approves it, in the target's Build Settings set
   `CODE_SIGN_ENTITLEMENTS` to `Config/FillMeUp.entitlements` for all SDKs, and
   enable the CarPlay capability on the App ID in the developer portal.

## Before submitting to the App Store

- [ ] Proxy deployed, and Release build pointed at it (no client secret in the app).
- [ ] CarPlay entitlement approved and applied to device builds, or remove the
      CarPlay scene from `Config/Info.plist` to ship phone-only first.
- [ ] Privacy policy URL (App Store Connect requires one). Location is used on
      the device only and is never sent anywhere; the proxy receives no user data.
- [ ] App Privacy answers: "Data Not Collected".
- [ ] Replace the placeholder app icon if you want something nicer.
- [ ] Screenshots (6.9" iPhone, and CarPlay if approved).

## Notes on the data

- Prices are converted to pence per litre whatever unit the feed uses; values
  outside 50p–500p are treated as feed errors and dropped.
- Prices older than 14 days are hidden, so a stale "cheapest" never tops the list.
- Temporarily or permanently closed stations are hidden.
- Attribution "Prices are reported by forecourts to the UK Government Fuel
  Finder scheme" is shown under the list, as the API terms require.
