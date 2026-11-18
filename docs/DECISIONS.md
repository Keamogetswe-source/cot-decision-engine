# Decision Log

Choices that shape the engine, with the reason and the current status. A rule changes here first, then in `STRATEGY_SPEC.md`.

| ID | Decision | Status |
|---|---|---|
| D-001 | The 26-week window includes the current week | Accepted |
| D-002 | Labels follow the index; a sign mismatch gets a note | Accepted |
| D-003 | A zero-range window gives NEUTRAL plus a data-quality warning | Accepted |
| D-004 | Overlay "Bullish" and "Bearish" include unwind and trend labels; Growth / Reflation needs both AUD and CAD | Accepted |
| D-005 | `engine.py` is built at the start of Milestone 3 | Accepted |
| D-006 | Python with `requests`, `pandas` and `pytest`; flat modules in `src/` | Accepted |
| D-007 | How the SQLite ledger persists between GitHub Actions runs | Open |
| D-008 | The fetcher pulls 40 weeks of history by default | Accepted |

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

## D-006: Tooling

**Context:** The master prompt asks for Python, `pytest` and a Socrata fetcher but names no libraries.

**Decision:** `requests` for the API, `pandas` for the rolling windows, `pytest` for tests. Modules live directly in `src/` and are imported as `src.<module>`. Tests are written alongside each module.

**Status:** Accepted at the start of Milestone 2.

## D-007: Ledger persistence on GitHub Actions (open)

**Context:** A GitHub Actions runner starts from a clean filesystem every run, so the SQLite ledger has nowhere to live between weeks.

**Options:**
1. Commit the weekly `.db` file back to the repository.
2. Rebuild the ledger from cached CFTC data on every run.

**Status:** Open. Decide during Milestone 3.

## D-008: Fetch window

**Context:** A full signal needs at least 27 weeks of history (D-001). Holiday delays or missing weeks can leave gaps.

**Decision:** The fetcher pulls 40 weeks of history by default, a buffer of 13 weeks. The window is a function parameter, not a strategy rule.

**Consequences:** The validator (Milestone 2) reports contracts that still have fewer than 27 usable weeks.
