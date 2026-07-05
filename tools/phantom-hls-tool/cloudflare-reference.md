# Cloudflare Cache & CORS — Reference Note

## Cache Rules

### 1. HLS Segments — Long Cache

|                       |                                                                                                                                                                                                                            |
|-----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Match**             | URI Path ends with `.m4s` OR ends with `.ts`                                                                                                                                                                               |
| **Cache eligibility** | Eligible for cache                                                                                                                                                                                                         |
| **Edge TTL**          | Ignore cache-control header → **1 year**                                                                                                                                                                                   |
| **Browser TTL**       | Override origin → **1 year**                                                                                                                                                                                               |
| **Why**               | Segments are immutable — produced once, never change. They carry the traffic, so they sit on the edge for a year and rarely hit R2. The `.ts` branch is future-proofing; we ship fMP4 (`.m4s`), but the rule catches both. |

### 2. HLS Manifests — No Cache

|                       |                                                                                                                                                                                                                                                    |
|-----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Match**             | URI Path ends with `.m3u8`                                                                                                                                                                                                                         |
| **Cache eligibility** | **Bypass cache**                                                                                                                                                                                                                                   |
| **Edge/Browser TTL**  | n/a (bypass hides these)                                                                                                                                                                                                                           |
| **Why**               | Manifests are tiny (KB) and few requests per view. Bypassing keeps them always fresh — update a ladder or rendition and it reflects instantly, no purge. Chosen over the Free-plan 2-hour minimum TTL because a manifest never needs caching here. |

There are only two file types in HLS (`.m4s`/`.ts` and `.m3u8`), so
these two rules cover everything. No third cache rule needed.

---

## Transform Rule — Vary: Origin

|            |                                                                                                                                                                                                                                                                                                                                                                                                                          |
|------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Match**  | URI Path ends with `.m4s` OR `.mp4` OR `.m3u8`                                                                                                                                                                                                                                                                                                                                                                           |
| **Action** | Set static header → `Vary: Origin`                                                                                                                                                                                                                                                                                                                                                                                       |
| **Why**    | R2 doesn't send `Vary: Origin`. Without it, a non-CORS response (native player) and a CORS response (Vidstack) share one cache entry — so a cached non-CORS `init.mp4` gets served to a CORS request and the browser reports "No Access-Control-Allow-Origin" even though curl shows the header. Adding `Vary: Origin` splits the cache by origin. Path-agnostic, so it covers new paths (e.g. `quickstart-guide/`) too. |

**Diagnostic signature of the bug this fixes:** curl shows correct CORS
headers but the browser serves a stale non-CORS response. That curl-vs-
browser contradiction = cache poisoning → this rule is the fix. After
adding it, purge cache once (and test in Incognito).

---

## Upload headers (set at upload, not a dashboard rule)

Cache-Control and Content-Type are applied by rclone at upload time, not
by a rule. The Cache Rules above override cache-control at the edge
anyway, but correct upload headers keep the origin honest.

`--s3-no-check-bucket` is required: the bucket-scoped token can't call
CreateBucket, so without this flag rclone 403s on the pre-flight check.
---

## One-line summary

Segments cached 1 year immutable; manifests bypassed (always fresh);
`Vary: Origin` splits the cache so CORS and non-CORS don't collide; CORS
allows the player's origins with Range. Two file types, two cache rules,
one transform rule, one CORS policy — nothing more needed.