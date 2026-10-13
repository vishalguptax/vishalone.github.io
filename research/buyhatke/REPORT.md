# BuyHatke teardown: can we build a better one?

Date: 2026-10-13. Scope: price chart, price alerts, and loot deals.

## Short answer

**Yes, we can build it, and we can make the price chart more accurate than BuyHatke's.**
The code is not the hard part. The data is: product history only exists from the day you
start recording it, and Amazon and Flipkart actively block scrapers. BuyHatke's real
advantage is roughly a million extension installs that see prices every day. A new
product has to solve data acquisition first.

## How far the reverse engineering got (and why)

I followed REA's (`morluto/rea`) `reverse-engineer-anything` skill. REA 6.4.0 runs in
this environment, but the cloud container's network policy **blocks** `buyhatke.com`,
`clients2.google.com`/`chromewebstore.google.com` (extension download) and the APK mirrors.
So I could not pull BuyHatke's actual extension or app code here. Everything below is
labeled by how well it is supported:

- **Observed**: seen directly in an artifact or an official listing.
- **Inferred**: the most likely mechanism, but not proven from BuyHatke's code.
- **Unknown**: needs the code-level teardown (`re-kit.sh`, run on your machine).

### Observed

| Fact | Source |
|---|---|
| Chrome extension `ojplmecpdpgccookcobabopnaifgidhf`, "Buyhatke: Price History & Tracker, Spend Lens", MV3, v5.1.167 (updated 2026-10-02), ~1M installs, 4.78★ | Chrome Web Store / extpose / chrome-stats listings |
| The extension's free price graph shows **3 months** of history | Chrome Web Store description |
| Alerts are user-set target prices, delivered by **email and push** (web + app) | Chrome Web Store description |
| The graph icon turns **red** when a price drop is likely soon, so they do a price-prediction step | Third-party review, buyhatke.com product page copy ("price prediction") |
| The extension's host permissions include multiple BuyHatke backends, for example `node3.buyhatke.com` and `tracking.buyhatke.com` | Extension metadata surfaced via search |
| Store identity is a numeric **`pos`** (store/"position" ID). The old coupon API was `http://coupons.buyhatke.com/PickCoupon/FreshCoupon/getCoupons.php?pos=<storeId>` | Source of `shobhitagarwal1612/Buyhatke` (2017), `FetchCouponCodeTask.java:17` |
| B2B "Pricing Intelligence" product exposes an authenticated `/v1/prices/{sku}` API with up to 2 years of history | pricing-intelligence.buyhatke.com |
| The catalogue was ~30M products from 300+ sites by 2015 | YourStory 2015 |
| Users publicly complain that results are inaccurate | MouthShut review, Quora thread |

### Inferred (verify with the kit)

1. **Crowd-sourced price collection.** On a supported product page, the content script
   reads the price and stock, sends it to BuyHatke (`tracking.`/`node*.` hosts), and gets
   back the stored history to draw the graph. That is how a free tool can cover 30M+
   SKUs without crawling all of them. Popular items get sampled often and long-tail items
   rarely, which explains the gaps and "inaccurate" complaints.
2. **Server-side crawl for watched items.** Any product with an active alert has to be
   re-checked without a user visiting it, so there is a crawler or scheduled fetcher keyed
   by `(pos, store product id)`.
3. **Prediction is a heuristic.** Most likely it checks the current price against the
   recent min/median and against the sale calendar (BBD, Great Indian Festival), not a
   real ML forecast.
4. **Loot deals** probably come from the same price stream. A large drop against the
   item's history gets flagged and pushed to the deals feed and notifications.

### Unknown (needs the code)

- Exact chart and alert endpoints, request signing or auth, and the response schema
- Sampling frequency per product, and whether points are per-seller or buy-box only
- Whether bank offers or coupons are folded into the plotted price
- How the "red icon" prediction is computed

To close these, run `research/buyhatke/re-kit.sh extension` on a machine with normal
internet access. Then point an agent with REA connected at
`buyhatke-work/extension-evidence.json` and ask it to trace the price-graph and alert
features from the hosts that `re-kit.sh grep` prints. For the app, pull the APK from your
own phone (`adb shell pm path <pkg>` then `adb pull`) and run `re-kit.sh apk`. For the
live API, save a DevTools HAR while a product's graph loads and run `re-kit.sh har`.
Static analysis does not execute anything. The HAR step only reads traffic you
recorded yourself.

## Building it better

### 1. A more accurate price chart

The usual sources of chart error, and the fix for each:

| Error source | Fix |
|---|---|
| Sparse sampling: one point per day or per visit hides a 3-hour lightning deal | **Store change events, not daily samples.** Save a row only when the price changes, with `first_seen` and `last_confirmed`. Draw a **step chart**, because prices are piecewise-constant and a sloped line between points invents prices nobody was offered. |
| Variant mix-up (color, size, storage) folded into one series | Key on the exact listing: Amazon **ASIN**; Flipkart **`pid` + `lid`** (product + listing) per variant |
| Seller changes and the buy box switching to a third-party seller | Record `seller_id`, `fulfilled_by` and `buybox` per observation. Default the chart to the buy-box price, with a per-seller toggle. |
| MRP or strike-through price recorded as the price | Read the **structured data** (JSON-LD `offers.price`, the page's embedded state JSON), not visible text |
| Out-of-stock periods drawn as a price | Store `in_stock`, and show gaps instead of carrying the last price forward |
| Bank or card offers ignored, so the "real" price is wrong | Plot two series: **list price** and **best effective price** (after coupon, bank offer, exchange), with the offer named |
| Bad or poisoned crowd data | Accept a client observation only if the server's own re-fetch within N minutes agrees, or if K independent clients agree. Rate-limit per install. |
| Silent crawler failures shown as "price unchanged" | Show **last verified at** on the chart, and grey out stale segments |

Sampling policy: adaptive. Re-fetch every 10–15 min for items with alerts or high traffic
and during sale events, a few times a day for normal items, and from crowd data only for
the long tail. Keep history forever (BuyHatke's free tier shows 3 months) and add 1Y/All
ranges plus min, max and median markers.

### 2. Price alerts

- Rule per user: `(listing, target_price | % drop | back-in-stock | any-seller vs fulfilled-only)`.
- **Event-driven evaluation.** Every new price change event is checked against the rules
  on that listing, so there is no polling of the rules table. Watched listings move up to
  the fast crawl tier automatically.
- Hysteresis and dedupe: fire once on crossing below the target, and re-arm only after
  the price goes back above `target + x%`.
- Channels: Web Push (VAPID) from the extension or PWA, **Telegram bot** (cheap, instant,
  popular with Indian deal hunters), email. Mobile push comes later.
- Re-verify the price with a fresh fetch right before sending, so you never alert on a
  stale or poisoned price.

### 3. Loot deals

The deal detector runs on the same change-event stream:

- `drop_pct` vs the 30-day and 90-day **median** (not vs MRP, which sellers inflate)
- **all-time-low** flag, and a **price-error** flag: a drop of more than ~60% or more
  than 4σ below the history, which usually means a pricing glitch and sells out in minutes
- Confidence: require a second independent fetch, and skip it if stock is 0 or the seller
  rating is low
- Publish to a site feed, a **Telegram channel**, and in-extension notifications. Rank by
  absolute savings × category popularity.
- Seed coverage: crawl the stores' deal and lightning-deal pages and category bestseller
  lists every few minutes, so new candidates show up before any user visits them.

### Proposed architecture

```
Chrome MV3 extension ──(observed price, listing id, seller, stock)──► Ingest API
        ▲                                                             │ validate / dedupe
        │ chart + alerts UI                                           ▼
        │                                     Postgres + TimescaleDB (price_events hypertable)
   Web app / PWA ◄── Chart API (step series, min/median, last-verified) ◄─┤
                                                                       │
   Crawler workers (queue, priority by alerts/traffic/sale) ──────────►┤
                                                                       ▼
                            Change-event stream ─► Alert engine ─► Push / Telegram / Email
                                                └► Deal detector ─► Deals feed / Telegram channel
```

### Phased plan

1. **MVP (2–3 weeks):** an extension that reads JSON-LD price on Amazon.in and
   Flipkart, an ingest API, a Timescale store and a step chart in a popup. Collect your own
   history from day 1.
2. **Alerts:** target-price rules, a fast crawl tier for watched items, a Telegram bot
   and Web Push.
3. **Deals:** the drop detector, a deal-page crawler and a public Telegram channel.
4. **Coverage and trust:** more stores (Myntra, Croma, Ajio, …), bank-offer
   parsing, a "last verified" UI and crowd-data validation.

## Risks to plan for

- **History backfill does not exist.** You can't buy or scrape someone else's past
  prices legitimately, and BuyHatke's API is for their B2B customers. Your chart will be
  thin for the first months, so start collecting immediately and expect the
  crowd-sourced extension to give the most coverage.
- **Store terms and anti-bot.** Amazon and Flipkart terms restrict automated scraping
  and both rate-limit hard. Prefer user-side observation in the extension plus official
  affiliate APIs where they exist, and keep server crawling polite and limited to watched
  items.
- **Don't reuse BuyHatke's private endpoints in production.** The teardown is for
  understanding the design. Calling their undocumented APIs would break their terms and
  could stop working at any time.
- **Extension privacy.** Collect only product-page data. Never send browsing history or
  logged-in page content. Chrome Web Store review checks this.
