# BuyHatke teardown: how it works and how we build a better one

Date: 2026-10-13. Target: BuyHatke Chrome extension **v5.1.170** (ID
`ojplmecpdpgccookcobabopnaifgidhf`, MV3), supplied as an unpacked zip.

## Verdict

**Yes, we can build it, and the price chart can be more accurate than BuyHatke's.**
Their "secret" is not an algorithm. It is about a million installed extensions working as
a distributed price sensor and crawler. The math behind their chart, buy advice and deal
scores is simple, and all of it is in the extension. The hard part for us is getting
enough price observations, not writing the logic.

**Biggest risk:** data acquisition. BuyHatke gets its data by running crawl jobs inside
users' browsers. Copying that without clear consent is a privacy and Chrome Web Store
policy risk, so we need a cleaner way to get the same coverage (see "Building it better").

## Method and evidence

- **REA** `analyze-javascript-application` on the unpacked extension:
  - Evidence ID: `ev_29a36270f47f6fbc1295a2829ab2ab95f00c93eac1c85afb64451c5eaf7bbbdd`
  - Artifact SHA-256: `4ea26699…51dd9dc`
  - 177 files, 145 JS files parsed, 0 parse failures, 2,054 findings
  - Semantic coverage is **partial** because REA hit result-size budgets on the largest
    bundles; those facts were kept per file. Summary: `evidence/rea-summary.json`.
- **Manual reading** of the minified bundles REA inventoried. Citations are
  `file @ character offset`. The bundles are minified, so names like `bA` and `Ht` are the
  minifier's, not BuyHatke's.
  - `SW` = `assets/service-worker.js-CcYZKfWJ.js` (sha256 `4d222934…`)
  - `UI` = `assets/utility_all2-BZFgRR7o.js` (sha256 `561df09d…`)
  - `PB` = `assets/platformBlockedHosts-DeF2bP2f.js` (sha256 `3aa6bcd4…`)
- Everything here is **static**. I executed nothing, made no requests to BuyHatke, and
  did not capture live traffic, so response *values* are not observed. Response
  *shapes* below come from the code that parses them.
- Labels: **Observed** (seen in code), **Inferred** (most likely, not proven),
  **Unknown**.

## How each feature actually works

### 1. Price chart (Observed)

- **Request:** `GET https://graph.bitbns.com/graphCache/getPredictedData?…` with the
  product's `pos` (store ID) and `pid`, plus a resolved `storeId` for quick-commerce
  stores (`SW @ ~684k`, `~693k`). BuyHatke runs on infrastructure shared with **Bitbns**
  (same founders): `graph.bitbns.com` and `search-new.bitbns.com` serve the graph, configs,
  deals and comparisons.
- **Auth:** the header `x-api-token` is `AES-CBC({appId: ext_id, appAuth: ext_auth,
  platform})`, encrypted with a **key and IV hard-coded in the extension** (`PB`, function
  `Ht`). That is obfuscation, not security: anyone with the extension can mint tokens.
  The key is not reproduced here.
- **Response shape:** a list of price **runs** `{from, to, price}`. The client expands each
  run into one point per day (`PB` function `Mt`, imported by the UI as `e0`). So the
  server already stores **price-change intervals**, not daily samples. Today's on-page
  price is appended as the last point (`UI`, around `var c=e0(r)`).
- **Ranges:** 1M / 3M / 6M / 1Y / All, filtered on the client. The listing's "3 months"
  is just the default tab.
- **Effective-price line:** the chart can redraw each point after bank, card and coupon
  offers (`UI` function `iD`). Offer data comes from `search-new.bitbns.com/buyhatke/offers/*`.
- **Sale markers:** a sale calendar of `{from, to}` periods gives the lowest price seen
  during past sales (`UI` `A1` / `xT`).
- **Buy advice (the "red/green" verdict)** is a plain comparison (`UI` function `AT(min,
  max, avg, current, available)`):
  - not available → "Currently unavailable! Set Alert."
  - min == max → "Constant price"
  - current ≤ min → "All-Time Low"
  - current < avg → "x% lower than average"
  - avg < current < max → "x% higher than average"
  - current ≥ max → "Price at its peak!"

  There is no ML model despite the endpoint name `getPredictedData`. (Inferred: the server
  may add a prediction field, but no client code consumes one.)
- **Known weakness:** the UI fires a `NoPricePointInLast3Days` analytics event (`UI`,
  function `nc`). BuyHatke tracks stale history as an internal problem, which matches the
  public "inaccurate" complaints.

### 2. Price collection: users are the sensors (Observed)

- **`ext1.buyhatke.com/extTest/sendPair`**: on listing, search and quick-commerce pages, the
  extension uploads arrays of `{pid, price, prod (title), image, storeId}` with
  `ext_id/ext_auth` (`SW` function `Ze`, ~641k).
- **`extension-apis/productDetails/save`** and **`searchProducts/save`** upload full product
  details and search results. `sendNoPrice` reports pages where no price was found.
- Page parsing is **config-driven**. Per-store selectors (title, price, seller, department,
  description…) come from JSON configs under `search-new.bitbns.com/extension/configs-ext/prod/`.
  So BuyHatke can fix a broken store parser without shipping a new extension.

### 3. Distributed crawling in users' browsers (Observed)

- **Hourly** (`puMs` timer): `GET extension-apis/fetchUrls` returns a list of URLs. The
  extension fetches each one, extracts the product ID, and posts the results to
  `getPIDSfromURL` (`SW` ~791k).
- **Every 2 hours** (`prMs`): `GET extension-apis/fetchUrlForDeals` returns a URL. The
  extension downloads that page and POSTs the **full HTML** to
  `https://4c8a9e7a.buyhatke.com/spidy/telegramDeals`. This is how their Telegram deal
  feed gets fresh pages.
- **Server-scheduled jobs** (`spidyDistChrome` / `spidyDistGlobChrome`): the server hands
  the extension a job (`job_id`, `base_url`, headers, retries). The extension runs it and
  returns the result (`SW` ~1.18M). Readiness is checked first via
  `utility.buyhatke.com/spidy/isReadyExt`.
- **Inferred:** because these requests run inside the user's browser with
  `<all_urls>` access, the stores see an ordinary residential user, which avoids the
  anti-bot blocking a server crawler would hit.
- **Observed, related:** the extension calls Amazon's recent-search suggestion API and
  **deletes recent-search entries** from the user's Amazon account (`SW` function `sy`,
  ~648k). Inferred: this cleans up searches the extension ran on the user's behalf for
  price comparison.

### 4. Price alerts (Observed)

- **Create:** `POST https://api.buyhatke.com/paapi/priceAlert` (form data: `prod, price,
  price_set, image, url, pos, pid, sitepos, ext_id, auth_val`). Siblings:
  `paapi/stockAlert`, `showAlerts`, `removeAlert`, `updatePriceAlert`,
  `priceAlertWishlist`, and `paapi/grocery/*`.
- **Checking:** a timer runs every 2 h and, at most **once per 24 h**, the extension
  re-downloads the page of **every product the user has an alert on** from the user's
  browser. It POSTs `{productID, productPOS, productLink, fetchedHTML, …}` to
  `<spidy host>/spidy/watchPriceResponse`, waiting 3 s between products (`SW` function
  `Ty` / `fv`, ~1.176M). It also re-checks a random **10%** of search results as
  "stale" checks.
- **Inferred:** server-side checks exist too, but each user's own browser is a main
  freshness source. A user whose browser is off gets slower alerts.
- **Delivery:** Chrome GCM plus Web Push (`chrome.gcm.register`,
  `pushManager.getSubscription`), email, and a **Telegram bot**
  (`extension-apis/telegramBot/connectStatus`).

### 5. Loot deals (Observed): the scoring algorithm runs in the extension

`SW` function `bA` (~637k):

1. For each product seen on a page, fetch stats from `POST extension-apis/thunder/getPidDataV2`
   `{pos, pids}`, cached for 10 min. Fields: `avg`, `avg1mon`, `avgbbd` (average during
   Big Billion Days / sale events), `min` (all-time), `min6` (6-month), `pnt` (data points).
2. Score five components with base weights **sale 30, pump 25, all-time-low 20,
   six-month-low 15, three-month-avg 10**. Each one decays linearly as the current price
   moves away from its reference: within 10% of the sale avg, all-time min or 6-month min,
   20% for the "pump" check, or a drop of up to 30% below avg. The weights shift when no
   sale data exists, or when the price is within 5% of the sale average but above the
   regular average.
3. **Flat-price penalty:** if every reference price (and the current price) sits between
   90% and 101% of their mean, meaning the product's price barely moves, all components
   are **halved**. Products with real price movement keep full scores.
4. Candidates with a score of at least `scoreThreshold` and at least `pointsThreshold` data
   points (from `search-new.bitbns.com/extension/configs-ext/prod/dealsValidity.json`)
   are batched and sent every **5 min** to `extension-apis/dealsBurst/sendDeals`.

So every user browsing a category page is a deal detector. Other deal sources:
`curated/pushCuratedDeals`, `ext1.buyhatke.com/amazon/lightDeals.php`,
`search-new.bitbns.com/buyhatke/deals` and `/exclusiveDeals`, and the Telegram crawl in §3.

### 6. Store coverage (Observed, partly)

- Stores are numeric **`pos`** IDs used everywhere (e.g. `6660` JioMart, `25850` JioMart
  quick-commerce, plus `63`, `2`, `429`, `25622` in special-case code).
- Supported surfaces seen: Amazon, Flipkart, Myntra, Snapdeal, JioMart, Blinkit, Zepto,
  BigBasket, DMart, Swiggy, Zomato, Meesho, AliExpress, Temu, brand stores (Apple,
  Samsung, Mi, Lenovo, Realme), Shopify stores, plus hotels and flights.
- **Unknown:** the full `pos` → store mapping. It is served from `getPosDetails` /
  `posurlConfig.json`, not shipped in the extension.

### 7. Other behaviour worth knowing (Observed)

- Permissions: `<all_urls>`, `cookies`, `webRequest`, `tabs`, `gcm`,
  `declarativeNetRequestWithHostAccess`, and `incognito: spanning`.
- **Affiliate:** links go through `redirect.buyhatke.com/Navigation/?pos=…` and
  `ch.buyhatke.com/bhs/rd/go/`; there is also `affiliationCashback/markStatus`.
  Inferred: affiliate commission is the main revenue source.
- **Spend Lens** uploads order-history and cart data, encrypted with AES-GCM using a
  server-issued key rotated every 6 h (`postUpdateNew` / `postUpdateOthers`,
  `spend-apis/verification/keyEnc`).
- Heavy analytics: `logger.`, `t.`, `tracking.`, `analytics/track/*`, `sendTelem`.

## Endpoint summary

| Purpose | Endpoint |
|---|---|
| Price history (graph) | `GET graph.bitbns.com/graphCache/getPredictedData` + `x-api-token` |
| Price stats for deal scoring | `POST ext1.buyhatke.com/extension-apis/thunder/getPidDataV2` |
| Crowd price upload | `POST ext1.buyhatke.com/extTest/sendPair`, `/extTest/sendCurrent`, `extension-apis/productDetails/save` |
| Deal candidates | `POST ext1.buyhatke.com/extension-apis/dealsBurst/sendDeals` |
| Crawl jobs | `extension-apis/fetchUrls`, `fetchUrlForDeals`, `…/spidyDistChrome`, `4c8a9e7a.buyhatke.com/spidy/telegramDeals` |
| Alert create / list / remove | `api.buyhatke.com/paapi/{priceAlert,stockAlert,showAlerts,removeAlert,updatePriceAlert}` |
| Alert re-check upload | `<spidy host>/spidy/watchPriceResponse` |
| Telegram link | `ext1.buyhatke.com/extension-apis/telegramBot/connectStatus` |
| Bank and card offers | `search-new.bitbns.com/buyhatke/offers/*` |
| Store parsing configs | `search-new.bitbns.com/extension/configs-ext/prod/*.json` |

## Data model (as implied by the code)

- **Listing key:** `(pos, pid)`, plus `storeId` for quick-commerce (price depends on the
  dark store or pincode).
- **Price history:** runs `{from, to, price}`, expanded client-side to daily points.
- **Product stats:** `{avg, avg1mon, avgbbd, min, min6, pnt}`.
- **Alert:** `{ext_id, pos, pid, url, prod, image, price_at_set, target_price}`.
- **Deal candidate:** `{pid, pos, totalScore, price, oos, points, isCurrent}`.

## Building it better

**What to copy:**
- store price as change runs
- config-driven per-store parsers you can update without a release
- the effective-price-after-offers line
- the deal score idea (current price vs sale avg, all-time min, 6-month min, recent avg)

**What to do better:**

| BuyHatke today | Ours |
|---|---|
| Runs expanded to daily points, so intra-day lightning deals vanish | Keep exact `first_seen` / `last_confirmed` timestamps and draw a **step chart** with intra-day resolution |
| Stale history (`NoPricePointInLast3Days`) is invisible to the user | Show "last verified" on the chart and grey out unverified stretches |
| Variant, seller and buy-box changes are folded into one `pid` | Key by exact variant (ASIN / Flipkart `pid`+`lid`) and record `seller`, `fulfilled_by`, `buybox` on every point |
| Crowd uploads trusted from client-side scraping | Accept a point only after a server re-check or K independent agreeing clients; rate-limit per install |
| Alert freshness depends on the user's browser being on (once per 24 h) | Watched items move to a server fast lane (10–15 min, faster during sales), and the price is re-verified right before notifying |
| Rule-based "advice" with no confidence | Same transparent rules, plus "N data points over D days" so users can judge |
| Deal scoring on clients, thresholds hidden | Score on the server from the change stream, flag likely price errors (more than 60% or 4σ below history), publish to Telegram plus the web feed with the reason shown |
| Users' browsers used as a hidden crawler, Amazon search history deleted | **Don't.** Collect only what the user's own page shows, with clear opt-in. Use official affiliate APIs and polite server fetching for watched items. |

**Architecture:** an MV3 extension (reads JSON-LD / page-state, opt-in sharing) feeds an
ingest API with validation. Data goes into Postgres + TimescaleDB as `price_events`. A
change stream feeds the alert engine (Web Push / Telegram / email) and the deal detector
(feed + Telegram channel). Crawler workers re-check watched items on a priority schedule.

**First 3 build steps:**
1. Extension MVP for Amazon.in and Flipkart: read price, seller and stock from structured
   data, then send opt-in observations to an ingest API that stores change events.
2. A step-chart UI with 1M/3M/6M/1Y/All, min/avg/max markers, "last verified", and the
   same transparent buy-advice rules.
3. Alerts: target-price rules, a fast re-check tier for watched items, Telegram bot and
   Web Push. Then add the deal detector on the same event stream.

## Remaining risks

- **No backfill.** Past prices can't be obtained legitimately. History starts on the day
  we start collecting.
- **Store terms and anti-bot.** Server-side scraping of Amazon and Flipkart is
  restricted. Lean on user-side observation (with consent) and affiliate APIs.
- **Do not call BuyHatke/Bitbns endpoints** from our product. The token scheme is weak,
  but using it would still be unauthorized access to their API.

## Checklist

| # | Question | Status |
|---|---|---|
| 1 | Price chart endpoint, request, response, rendering | **Answered**. Response *values* are not observed because no live traffic was captured; a HAR would confirm them. |
| 2 | Does the extension send prices back? | **Answered**: yes, `sendPair` / `productDetails/save` / `searchProducts/save` |
| 3 | How the "red icon / wait" verdict works | **Answered**: rule-based min/avg/max comparison; no client-side ML |
| 4 | Alerts: create, check, deliver | **Answered**. Server-side checking frequency is unknown. |
| 5 | Loot deals | **Answered**: client-side scoring + `dealsBurst`, plus curated, Amazon light-deals and Telegram crawl |
| 6 | Store coverage and parsing | **Partly answered**: config-driven selectors; the full `pos` mapping is server-side |
| 7 | Affiliate, tracking, permissions | **Answered** |

## Reproducing

`re-kit.sh extension` downloads and unpacks the extension and runs REA on it. Save a
DevTools HAR while a product's price graph loads, then run `re-kit.sh har <path>` to
confirm the live response values.
