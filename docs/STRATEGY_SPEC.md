# Strategy Specification

**Status:** Draft v0.2 (Milestone 1). Rules are transcribed from `MASTER_PROMPT.md`. The open questions from v0.1 are resolved in `DECISIONS.md` and reflected below.

## 1. Purpose

A weekly cross-asset decision engine built on CFTC Commitments of Traders (Legacy Futures-Only) data. It classifies how large speculators are positioned in each tracked contract and summarises the result as a macro regime.

The lens is that of an insurance underwriter: look for where large players are paying up for protection against geopolitical shocks, inflation or slowdown before the shift spreads across markets.

## 2. Data

| Item | Value |
|---|---|
| Report | CFTC Commitments of Traders, Legacy Futures-Only |
| Primary source | CFTC Socrata REST API, dataset `6dca-aqww` |
| Fallback source | `deacot{year}.zip` |
| Position date | Tuesday |
| Publication | Friday |
| Contract filter | 6-digit `CFTC Contract Market Code` only |

Because of the Tuesday-to-Friday lag, static net positioning is too slow for a one-week outlook. The engine combines week-over-week flow, a 26-week normalized index and commercial hedger divergence.

## 3. Contract Universe

| Group | Symbol | Contract | CFTC code |
|---|---|---|---|
| Safe-haven FX | JPY | Japanese Yen | `097741` |
| Safe-haven FX | CHF | Swiss Franc | `092741` |
| US benchmark / cyclical FX | USD | US Dollar Index (DXY) | `098662` |
| US benchmark / cyclical FX | EUR | Euro | `099741` |
| US benchmark / cyclical FX | GBP | British Pound | `096742` |
| US benchmark / cyclical FX | CAD | Canadian Dollar | `090741` |
| US benchmark / cyclical FX | AUD | Australian Dollar | `232741` |
| US benchmark / cyclical FX | NZD | New Zealand Dollar | `112741` |
| Commodities | XAU | COMEX Gold | `088691` |
| Commodities | WTI | NYMEX Crude Oil | `067651` |
| Equities | ES | E-mini S&P 500 | `13874A` |
| Sovereign rates | ZN | 10-Year U.S. Treasury Notes | `043602` |

For `ZN`: net long = bond buying / yields falling; net short = bond selling / yields rising.

## 4. Metrics

Computed for every contract, every week:

```
Spec_Net       = NonCommercial_Long - NonCommercial_Short
Comm_Net       = Commercial_Long    - Commercial_Short      (implied by Comm_COT_Index)
WoW_Flow       = Current_Spec_Net - Prior_Spec_Net

Spec_COT_Index = (Current_Spec_Net - 26Wk_Low) / (26Wk_High - 26Wk_Low) * 100
Comm_COT_Index = (Current_Comm_Net - 26Wk_Low) / (26Wk_High - 26Wk_Low) * 100
```

- Each index uses the 26-week low and high of its own net series (speculator or commercial).
- The window is the current week plus the 25 weeks before it. The prior-week index has its own window ending the week before (D-001). A full signal needs at least 27 weeks of history.
- If the 26-week high equals the low, the index is undefined. The contract is labelled NEUTRAL with a data-quality warning (D-003).

## 5. The Four Gates

Gates are evaluated in order, 1 to 4, and every contract gets exactly one label.

| Gate | Label | Condition | Play type |
|---|---|---|---|
| 1 | **BULLISH UNWIND** | Net short, and (`Spec_COT_Index <= 25` or prior week `<= 15`), and `WoW_Flow > 0` | Active counter-trend |
| 1 | **BEARISH UNWIND** | Net long, and (`Spec_COT_Index >= 75` or prior week `>= 85`), and `WoW_Flow < 0` | Active counter-trend |
| 2 | **EXTREME LONG** | `Spec_COT_Index >= 90` and `WoW_Flow >= 0`. Flag if `Comm_COT_Index <= 15` | No chase / fade watch |
| 2 | **EXTREME SHORT** | `Spec_COT_Index <= 10` and `WoW_Flow <= 0`. Flag if `Comm_COT_Index >= 85` | No chase / fade watch |
| 3 | **BULLISH TREND** | `20 <= Spec_COT_Index <= 80`, `WoW_Flow > 0` and `Spec_Net > 0` | Active trend |
| 3 | **BEARISH TREND** | `20 <= Spec_COT_Index <= 80`, `WoW_Flow < 0` and `Spec_Net < 0` | Active trend |
| 4 | **NEUTRAL** | All other states | No play |

The label follows the index, not the sign of `Spec_Net`. When the two disagree (for example `EXTREME SHORT` while `Spec_Net` is positive), the report adds a sign-mismatch note (D-002).

## 6. Macro Regime Readout

Generated after all contracts are scored. "Bullish" means BULLISH UNWIND or BULLISH TREND, "Bearish" means BEARISH UNWIND or BEARISH TREND, and "Exhausted Long" means EXTREME LONG (D-004).

- **Risk-Off / Insurance Bid:** `XAU` is Bullish, and at least one of `JPY`, `CHF` or `ZN` (bond buying) is Bullish, while `ES` is Bearish or Exhausted Long.
- **Growth / Reflation Bid:** `WTI` and `ES` are Bullish alongside cyclical FX (both `AUD` and `CAD` Bullish), while `JPY` and `CHF` are Bearish.
- **FX Cross Matrix:** Pair Bullish currencies against Bearish currencies only. Commodities and bonds are never paired into synthetic FX crosses.

## 7. Resolved Questions

| Question | Resolution | Decision |
|---|---|---|
| Does the 26-week window include the current week? | Yes; the prior-week index has its own window | D-001 |
| Label versus sign of `Spec_Net` | Label follows the index; mismatch gets a note | D-002 |
| Zero-range window | NEUTRAL with a data-quality warning | D-003 |
| Meaning of Bullish and Bearish in the overlay; AUD and CAD | Unwind and trend both count; both AUD and CAD required | D-004 |

Still open: how the SQLite ledger persists on GitHub Actions (D-007). That is an engineering choice, not a strategy rule.
