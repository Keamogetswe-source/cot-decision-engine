# Institutional Macro Flow & COT Decision Engine

A weekly cross-asset decision engine in Python. It reads CFTC Commitments of Traders (Legacy Futures-Only) data and classifies how large institutions are positioned across currencies, commodities, equities and sovereign debt.

> **Status:** Milestone 1 (planning and spec) in progress.

## The idea

Most COT tools read one currency pair at a time. This one reads institutional futures flow the way an insurance underwriter prices systemic risk: where are large players paying up for protection against geopolitical shocks, inflation or slowdown?

- **Commodities as barometers:** Gold (`XAU`) and Crude Oil (`WTI`)
- **Safe-haven vs. cyclical FX:** `JPY` and `CHF` against `USD` and `GBP`
- **Equities vs. bonds:** `ES` against `ZN`, and whether capital shelters in Treasuries or in Gold

Because CFTC data lags (Tuesday positions, published Friday), each contract is scored with week-over-week flow, a 26-week COT Index and commercial hedger divergence, then run through four decision gates. Full rules are in [`docs/STRATEGY_SPEC.md`](docs/STRATEGY_SPEC.md).

## Tracked contracts

`JPY` `CHF` `USD` `EUR` `GBP` `CAD` `AUD` `NZD` `XAU` `WTI` `ES` `ZN`, filtered strictly by CFTC Contract Market Code.

## Planned structure

```
docs/      STRATEGY_SPEC.md, DECISIONS.md, MASTER_PROMPT.md
src/       contracts, fetcher, validator, engine, storage, reporter, cli
tests/     test_engine, test_validator, test_storage
reports/   latest_matrix.md (auto-generated weekly)
```

## Roadmap

| Milestone | Scope | Days |
|---|---|---|
| 1. Planning & spec | README, strategy spec, decision log, GitHub Issues | 1–2 |
| 2. Data pipeline & validation | Socrata fetcher, zip fallback, caching, integrity checks | 3–5 |
| 3. Engine, SQLite ledger & reporting | Gates, macro regime, idempotent upserts, Markdown/CSV reports | 6–9 |
| 4. Testing, CI/CD & polish | Full pytest coverage, Saturday GitHub Actions run, architecture diagram | 10 |

## Disclaimer

Educational and research project. Not financial advice.
