# ai-scripts

Provider **adapter scripts** for talking to LLM backends — each takes a prompt (and optionally a
PDF/document), calls one provider, and returns JSON. These are the "channels" that higher-level
tools dispatch to via config.

One subdirectory per tool, each a standalone script with no build step. Put them wherever you
like; nothing here depends on where the repo lives.

| Tool | Backend | Notes |
|------|---------|-------|
| `gemini-query/` | Google Gemini API | prompt → JSON; `--ground` (Google-Search grounding), `--cache` (Context Cache), `--session` (conversation memory) |
| `gemini-files/` | Gemini Files API | upload a doc + query it (large-PDF attach); creates the Context Caches `gemini-query --cache` reads |
| `gemini-rag/`   | Gemini + retrieval | RAG helper (`.sh` + `.py` + `.cfg`) |
| `claude-query/` | Anthropic Claude | `--via api` (metered) or `--via claudecode` (Claude Code subscription) |
| `antigravity-query/` | Antigravity (`agy`) | flat-rate proxy to Gemini/Claude/GPT; exit `3`=5h cap, `4`=weekly cap |
| `liftwing-query/` | Wikimedia LiftWing | free, OpenAI-shaped; `--via tfproxy` for unlimited rate; exit `3`=rate limited |
| `xai-query/` | xAI Grok | metered, OpenAI-shaped; `--usage-file` emits token/cost JSON; exit `3`=rate limited |

## Token prices — `llm-rates.json`
Every consumer that computes a cost reads **`llm-rates.json`**. Do not hardcode a rate anywhere else.

The cost hierarchy, in order of preference:
1. **The cost the provider reports for the actual call.** xAI returns `usage.cost_in_usd_ticks`
   (1 USD = 1e10 ticks) — exact, and it accounts for cache discounts a static table cannot see.
   On the first live call the table was **1.93x** off for this reason. Where a provider does
   this, the file is only a drift detector.
2. **Rates from the file**, for providers with no per-call cost (Gemini).
3. **Nothing** — if a model is absent, report cost as unknown. Never `0.0`, never a guessed
   default. A confident wrong number is worse than a missing one, and the daemons abort at
   startup rather than run un-priced.

Every entry carries `source` and `verified`. This file exists because a consumer once ran for
months on a superseded model's rates, recorded as "reverse-solved from the log" — circular, since
the log had been written by those same constants, so nothing in it could ever contradict them.
The real rates were 20x and 30x higher. **Only comparing against the actual invoice caught it**,
so prefer an invoice over a docs page and re-verify periodically. Deduplication alone would not
have prevented this; provenance might.

## Conventions
- **Secrets are never stored here**, and are located by search rather than by hardcoded path.
  Each script looks in `~/scripts/secrets`, `~/.config/wikiget/secrets`, then
  `~/toolforge/scripts/secrets` (first match wins), so the *same file* runs unmodified on every
  host with no per-host fork to maintain. `-k <keyfile>` overrides the search.
- **LiftWing rate limits** are the whole story for `liftwing-query`. LiftWing defines three tiers:
  anonymous/authenticated = **100 req/hour shared across all `llm-*` models**; *known network*
  (Toolforge/WMCS) = unlimited; *approved bot* = unlimited. An OAuth 2.0 JWT does **not** raise the
  quota — it only changes the gateway's `x-wmf-ratelimit-class`. The tier comes from where the
  request *originates*, so for any real volume the answer is to make it originate from a
  Toolforge/WMCS address. **`--via tfproxy`** does that by forwarding through a proxy you run
  there; supply its URL, auth header and shared secret as `tfproxy.url`, `tfproxy.header` and
  `tfproxy.password` in a secrets directory. Any proxy taking the destination in `?target=`
  works. No token is sent in proxy mode.
- **LiftWing direct auth** (`--via direct`) needs an *OAuth 2.0* access token (a JWT). OAuth 1.0a
  consumer credentials are **not** accepted by the api.wikimedia.org gateway, so an existing
  1.0a consumer cannot be reused here. Register an owner-only OAuth 2.0 client at
  `meta:Special:OAuthConsumerRegistration/propose/oauth2`; owner-only tokens never expire.
- **xAI pricing is tiered at 200k prompt tokens** — crossing it *doubles* both the input and
  output rate for the entire request, so a 210k-token prompt costs more than twice a 190k one.
  `xai-query.sh` reports which tier a call landed in. Its default model
  (`grok-4.20-0309-non-reasoning`) is chosen deliberately: 1M context, cheapest tier, and no
  reasoning tokens. On `grok-4.6`/`grok-4.5`/`grok-4.20-multi-agent`, xAI documents that
  **reasoning cannot be disabled** — those reasoning tokens bill at the output rate and are
  reported *outside* `completion_tokens`, so naive accounting understates the bill. The script
  folds them in and warns; see `--usage-file` for the normalized record.

## License
Code is GPL-3.0; documentation is CC BY-SA 4.0. See [LICENSE.md](LICENSE.md).
