#!/usr/bin/env bash
# Day 2 setup for cot-decision-engine.
# Run from the repo root:  bash ~/Downloads/day2_setup.sh
set -euo pipefail

if [ ! -d .git ]; then
  echo "Run this from the repo root (the folder that contains .git)."
  exit 1
fi
if ! git remote get-url origin 2>/dev/null | grep -q "cot-decision-engine"; then
  echo "origin does not point at cot-decision-engine. Stopping so nothing lands in the wrong repo."
  exit 1
fi
if [ ! -f .gitignore ]; then
  echo "Note: no .gitignore yet. Add it before you commit."
fi

mkdir -p docs src tests reports

# ---------------------------------------------------------------- DECISIONS
cat > docs/DECISIONS.md <<'DOC_EOF'
# Decision Log

Choices that shape the engine, with the reason and the current status. A rule changes here first, then in `STRATEGY_SPEC.md`.

| ID | Decision | Status |
|---|---|---|
| D-001 | The 26-week window includes the current week | Accepted |
| D-002 | Labels follow the index; a sign mismatch gets a note | Accepted |
| D-003 | A zero-range window gives NEUTRAL plus a data-quality warning | Accepted |
| D-004 | Overlay "Bullish" and "Bearish" include unwind and trend labels; Growth / Reflation needs both AUD and CAD | Accepted |
| D-005 | `engine.py` is built at the start of Milestone 3 | Accepted |
| D-006 | Python with `requests`, `pandas` and `pytest`; flat modules in `src/` | Proposed |
| D-007 | How the SQLite ledger persists between GitHub Actions runs | Open |

---

## D-001: 26-week window

**Context:** The spec does not say whether the window includes the current week.

**Decision:** The window is the current week plus the 25 weeks before it. The prior-week index used by Gate 1 has its own window, ending the week before.

**Consequences:** Each contract needs at least 27 weeks of history for a full signal. The validator checks this in Milestone 2.

## D-002: Index versus sign

**Context:** The indices are relative to the 26-week range, so `EXTREME SHORT` can fire while `Spec_Net` is still positive, and `EXTREME LONG` while it is still negative.

**Decision:** The label follows the index, as written in the spec. When the sign of `Spec_Net` disagrees with the label, the engine records a sign-mismatch note.

**Consequences:** The report shows the note next to the label.

## D-003: Zero-range window

**Context:** If the 26-week high equals the low, the index formula divides by zero.

**Decision:** The index is undefined. The contract is labelled NEUTRAL with a data-quality warning.

**Consequences:** The validator detects zero-range windows (Milestone 2). The engine never divides by zero, and tests cover the case.

## D-004: Overlay wording

**Context:** The Macro Regime Readout uses "Bullish", "Bearish" and "Exhausted Long" without defining them. Growth / Reflation does not say whether one or both of AUD and CAD must be Bullish.

**Decision:**
- Bullish means BULLISH UNWIND or BULLISH TREND. Bearish means BEARISH UNWIND or BEARISH TREND.
- Exhausted Long means EXTREME LONG.
- Growth / Reflation needs both AUD and CAD Bullish.
- The FX Cross Matrix uses the same definition of active Bullish and Bearish.

**Consequences:** EXTREME labels and NEUTRAL never count as Bullish or Bearish.

## D-005: Where engine.py sits

**Context:** The four milestones in the master prompt do not mention `engine.py`.

**Decision:** The engine, with its tests, is built at the start of Milestone 3, before storage.

**Consequences:** The README roadmap reflects this.

## D-006: Tooling (proposed)

**Context:** The master prompt asks for Python, `pytest` and a Socrata fetcher but names no libraries.

**Proposal:** `requests` for the API, `pandas` for the rolling windows, `pytest` for tests. Modules live directly in `src/` and are imported as `src.<module>`. Tests are written alongside each module.

**Status:** Proposed. Confirm or change before Milestone 2.

## D-007: Ledger persistence on GitHub Actions (open)

**Context:** A GitHub Actions runner starts from a clean filesystem every run, so the SQLite ledger has nowhere to live between weeks.

**Options:**
1. Commit the weekly `.db` file back to the repository.
2. Rebuild the ledger from cached CFTC data on every run.

**Status:** Open. Decide during Milestone 3.
DOC_EOF

# ------------------------------------------------------------ STRATEGY_SPEC
cat > docs/STRATEGY_SPEC.md <<'DOC_EOF'
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
DOC_EOF

# -------------------------------------------------------------- SCAFFOLDING
cat > requirements.txt <<'DOC_EOF'
requests>=2.31
pandas>=2.0
pytest>=8.0
DOC_EOF

cat > pytest.ini <<'DOC_EOF'
[pytest]
testpaths = tests
pythonpath = .
DOC_EOF

touch src/__init__.py reports/.gitkeep

# ---------------------------------------------------------------- CONTRACTS
cat > src/contracts.py <<'DOC_EOF'
"""Tracked CFTC contract universe.

Codes are the 6-character CFTC Contract Market Codes used to filter Legacy
Futures-Only data. They are immutable: change them only through DECISIONS.md.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Group(str, Enum):
    """Asset group a contract belongs to."""

    SAFE_HAVEN_FX = "Safe-haven FX"
    CYCLICAL_FX = "US benchmark / cyclical FX"
    COMMODITY = "Commodities"
    EQUITY = "Equities"
    RATES = "Sovereign rates"


@dataclass(frozen=True)
class Contract:
    """One tracked futures contract."""

    code: str
    symbol: str
    name: str
    group: Group

    @property
    def is_currency(self) -> bool:
        """True for FX contracts, the only ones allowed in the FX Cross Matrix."""
        return self.group in (Group.SAFE_HAVEN_FX, Group.CYCLICAL_FX)


CONTRACTS: tuple[Contract, ...] = (
    Contract("097741", "JPY", "Japanese Yen", Group.SAFE_HAVEN_FX),
    Contract("092741", "CHF", "Swiss Franc", Group.SAFE_HAVEN_FX),
    Contract("098662", "USD", "US Dollar Index (DXY)", Group.CYCLICAL_FX),
    Contract("099741", "EUR", "Euro", Group.CYCLICAL_FX),
    Contract("096742", "GBP", "British Pound", Group.CYCLICAL_FX),
    Contract("090741", "CAD", "Canadian Dollar", Group.CYCLICAL_FX),
    Contract("232741", "AUD", "Australian Dollar", Group.CYCLICAL_FX),
    Contract("112741", "NZD", "New Zealand Dollar", Group.CYCLICAL_FX),
    Contract("088691", "XAU", "COMEX Gold", Group.COMMODITY),
    Contract("067651", "WTI", "NYMEX Crude Oil", Group.COMMODITY),
    Contract("13874A", "ES", "E-mini S&P 500", Group.EQUITY),
    Contract("043602", "ZN", "10-Year U.S. Treasury Notes", Group.RATES),
)

BY_CODE: dict[str, Contract] = {c.code: c for c in CONTRACTS}
BY_SYMBOL: dict[str, Contract] = {c.symbol: c for c in CONTRACTS}


def all_codes() -> list[str]:
    """Return every tracked CFTC Contract Market Code."""
    return [c.code for c in CONTRACTS]


def get_by_code(code: str) -> Contract:
    """Look up a contract by its CFTC code; raise KeyError if untracked."""
    try:
        return BY_CODE[code]
    except KeyError:
        raise KeyError(f"Untracked CFTC contract code: {code!r}") from None


def get_by_symbol(symbol: str) -> Contract:
    """Look up a contract by its symbol (for example 'XAU'); raise KeyError if untracked."""
    try:
        return BY_SYMBOL[symbol]
    except KeyError:
        raise KeyError(f"Untracked contract symbol: {symbol!r}") from None
DOC_EOF

cat > tests/test_contracts.py <<'DOC_EOF'
"""Sanity tests for the immutable contract universe."""

from dataclasses import FrozenInstanceError

import pytest

from src.contracts import (
    CONTRACTS,
    Group,
    all_codes,
    get_by_code,
    get_by_symbol,
)

EXPECTED_CODES = {
    "JPY": "097741",
    "CHF": "092741",
    "USD": "098662",
    "EUR": "099741",
    "GBP": "096742",
    "CAD": "090741",
    "AUD": "232741",
    "NZD": "112741",
    "XAU": "088691",
    "WTI": "067651",
    "ES": "13874A",
    "ZN": "043602",
}


def test_universe_has_twelve_contracts() -> None:
    assert len(CONTRACTS) == 12


def test_codes_are_unique_six_characters() -> None:
    codes = all_codes()
    assert len(set(codes)) == len(codes)
    assert all(len(code) == 6 for code in codes)


def test_symbols_are_unique() -> None:
    symbols = [c.symbol for c in CONTRACTS]
    assert len(set(symbols)) == len(symbols)


@pytest.mark.parametrize(("symbol", "code"), EXPECTED_CODES.items())
def test_symbol_maps_to_expected_code(symbol: str, code: str) -> None:
    assert get_by_symbol(symbol).code == code
    assert get_by_code(code).symbol == symbol


def test_only_fx_contracts_are_currencies() -> None:
    currencies = {c.symbol for c in CONTRACTS if c.is_currency}
    assert currencies == {"JPY", "CHF", "USD", "EUR", "GBP", "CAD", "AUD", "NZD"}


def test_safe_haven_group() -> None:
    safe = {c.symbol for c in CONTRACTS if c.group is Group.SAFE_HAVEN_FX}
    assert safe == {"JPY", "CHF"}


def test_unknown_lookups_raise_key_error() -> None:
    with pytest.raises(KeyError):
        get_by_code("000000")
    with pytest.raises(KeyError):
        get_by_symbol("BTC")


def test_contract_is_immutable() -> None:
    with pytest.raises(FrozenInstanceError):
        get_by_symbol("XAU").code = "000000"  # type: ignore[misc]
DOC_EOF

echo
echo "Day 2 files written:"
echo "  docs/DECISIONS.md  docs/STRATEGY_SPEC.md (v0.2)"
echo "  requirements.txt  pytest.ini  src/__init__.py  reports/.gitkeep"
echo "  src/contracts.py  tests/test_contracts.py"
echo
echo "Next: python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && pytest"
