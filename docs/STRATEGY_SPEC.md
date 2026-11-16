# Strategy Specification

**Status:** Draft v0.1 (Milestone 1). Rules below are transcribed from `MASTER_PROMPT.md`. Open questions are listed at the bottom and get resolved in `DECISIONS.md` before engine logic is locked.

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

Each index uses the 26-week low and high of its own net series (speculator or commercial).

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

## 6. Macro Regime Readout

Generated after all contracts are scored.

- **Risk-Off / Insurance Bid:** `XAU` is Bullish, and at least one of `JPY`, `CHF` or `ZN` (bond buying) is Bullish, while `ES` is Bearish or Exhausted Long.
- **Growth / Reflation Bid:** `WTI` and `ES` are Bullish alongside cyclical FX (`AUD`, `CAD`), while `JPY` and `CHF` are Bearish.
- **FX Cross Matrix:** Pair Active BULLISH currencies against Active BEARISH currencies only. Commodities and bonds are never paired into synthetic FX crosses.

## 7. Open Questions

To be answered by the lead architect and recorded in `DECISIONS.md`.

1. **26-week window:** Does it include the current week? Does the prior-week index (Gate 1) use its own trailing 26 weeks?
2. **Index vs. sign:** The indices are relative to the 26-week range, so `EXTREME SHORT` can fire while `Spec_Net` is still positive (and `EXTREME LONG` while it is still negative). Should the label ignore the sign, or should the report note the mismatch?
3. **Zero-range window:** If the 26-week high equals the low, the index is undefined. What label should the contract get (for example NEUTRAL with a data-quality note)?
4. **Overlay wording:** Does "Bullish" or "Bearish" in the overlay include both unwind and trend labels (Gates 1 and 3)? In Growth / Reflation, must both `AUD` and `CAD` be Bullish, or at least one?
