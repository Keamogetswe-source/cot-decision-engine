#!/usr/bin/env bash
# Day 3 setup for cot-decision-engine: the Socrata fetcher.
# Run from the repo root:  bash ~/Downloads/day3_setup.sh
set -euo pipefail

if [ ! -d .git ]; then
  echo "Run this from the repo root (the folder that contains .git)."
  exit 1
fi
if ! git remote get-url origin 2>/dev/null | grep -q "cot-decision-engine"; then
  echo "origin does not point at cot-decision-engine. Stopping so nothing lands in the wrong repo."
  exit 1
fi
if [ ! -f src/contracts.py ] || [ ! -f docs/DECISIONS.md ]; then
  echo "Day 2 files are missing (src/contracts.py or docs/DECISIONS.md). Finish Day 2 first."
  exit 1
fi

mkdir -p src tests

# ------------------------------------------------------------------ FETCHER
cat > src/fetcher.py <<'DOC_EOF'
"""Fetch CFTC Legacy Futures-Only positions from the Socrata API (dataset 6dca-aqww).

The fetcher returns raw weekly positions for the tracked contracts only. It
computes no metrics: nets, flows and indices belong to ``engine.py``.
"""

from __future__ import annotations

import os
import re
from datetime import date, timedelta
from typing import Any, Protocol, Sequence

import pandas as pd
import requests

from src.contracts import BY_CODE, all_codes

SOCRATA_URL = "https://publicreporting.cftc.gov/resource/6dca-aqww.json"
DATE_FIELD = "report_date_as_yyyy_mm_dd"
CODE_FIELD = "cftc_contract_market_code"

# Socrata column -> normalized column. If the API renames a field, fix it here.
FIELD_MAP: dict[str, str] = {
    "noncomm_positions_long_all": "noncomm_long",
    "noncomm_positions_short_all": "noncomm_short",
    "comm_positions_long_all": "comm_long",
    "comm_positions_short_all": "comm_short",
    "open_interest_all": "open_interest",
}
COLUMNS: list[str] = ["report_date", "code", "symbol", *FIELD_MAP.values()]

DEFAULT_LOOKBACK_WEEKS = 40
PAGE_SIZE = 1000
MAX_PAGES = 100
TIMEOUT_SECONDS = 30
_CODE_PATTERN = re.compile(r"[0-9A-Z]{6}")


class FetchError(RuntimeError):
    """The CFTC API could not be reached or returned something unusable."""


class HttpSession(Protocol):
    """The slice of ``requests.Session`` the fetcher needs (easy to fake in tests)."""

    def get(
        self,
        url: str,
        *,
        params: dict[str, Any],
        headers: dict[str, str],
        timeout: float,
    ) -> Any: ...


def default_start_date(
    today: date | None = None, weeks: int = DEFAULT_LOOKBACK_WEEKS
) -> date:
    """Return the first report date to request: ``weeks`` weeks before ``today``."""
    return (today or date.today()) - timedelta(weeks=weeks)


def build_where(codes: Sequence[str], start: date) -> str:
    """Build the SoQL ``$where`` clause for the given contract codes and start date."""
    for code in codes:
        if not _CODE_PATTERN.fullmatch(code):
            raise ValueError(f"Invalid CFTC contract code: {code!r}")
    code_list = ", ".join(f"'{code}'" for code in codes)
    return (
        f"{CODE_FIELD} in({code_list}) "
        f"AND {DATE_FIELD} >= '{start.isoformat()}T00:00:00.000'"
    )


def fetch_socrata(
    start: date | None = None,
    codes: Sequence[str] | None = None,
    *,
    session: HttpSession | None = None,
    app_token: str | None = None,
    page_size: int = PAGE_SIZE,
) -> pd.DataFrame:
    """Fetch weekly positions for the tracked contracts since ``start``.

    Returns a DataFrame with the columns in ``COLUMNS``, sorted by contract code
    and report date. Position columns use pandas' nullable ``Int64`` so a missing
    or non-numeric value becomes ``<NA>`` for the validator to report; it is never
    silently filled.

    Raises:
        FetchError: the API is unreachable, returns an error, or returns data
            that does not have the expected shape.
        ValueError: a code in ``codes`` is not a 6-character CFTC code.
    """
    start_date = start or default_start_date()
    code_list = list(codes) if codes is not None else all_codes()
    token = app_token or os.environ.get("SOCRATA_APP_TOKEN")
    headers = {"X-App-Token": token} if token else {}
    where = build_where(code_list, start_date)

    own_session = requests.Session() if session is None else None
    http: HttpSession = session if session is not None else own_session  # type: ignore[assignment]
    try:
        rows = _fetch_all_pages(http, where, headers, page_size)
    finally:
        if own_session is not None:
            own_session.close()
    return _to_frame(rows)


def _fetch_all_pages(
    http: HttpSession, where: str, headers: dict[str, str], page_size: int
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for page_number in range(MAX_PAGES):
        params = {
            "$where": where,
            "$order": f"{DATE_FIELD} ASC, {CODE_FIELD} ASC",
            "$limit": page_size,
            "$offset": page_number * page_size,
        }
        page = _get_json(http, params, headers)
        rows.extend(page)
        if len(page) < page_size:
            return rows
    raise FetchError(
        f"Stopped after {MAX_PAGES} pages; the query returned more rows than expected."
    )


def _get_json(
    http: HttpSession, params: dict[str, Any], headers: dict[str, str]
) -> list[dict[str, Any]]:
    try:
        response = http.get(
            SOCRATA_URL, params=params, headers=headers, timeout=TIMEOUT_SECONDS
        )
    except requests.RequestException as exc:
        raise FetchError(f"Could not reach the CFTC Socrata API: {exc}") from exc
    if response.status_code != 200:
        raise FetchError(
            f"CFTC Socrata API returned HTTP {response.status_code}: "
            f"{str(response.text)[:200]}"
        )
    try:
        payload = response.json()
    except ValueError as exc:
        raise FetchError("CFTC Socrata API returned invalid JSON.") from exc
    if not isinstance(payload, list):
        raise FetchError("CFTC Socrata API returned an unexpected response shape.")
    return payload


def _to_frame(rows: list[dict[str, Any]]) -> pd.DataFrame:
    if not rows:
        return _empty_frame()
    raw = pd.DataFrame(rows)

    required = {DATE_FIELD, CODE_FIELD, *FIELD_MAP}
    missing = sorted(required - set(raw.columns))
    if missing:
        raise FetchError(
            f"Response is missing expected columns {missing}. "
            f"Columns received: {sorted(raw.columns)}"
        )
    unknown = sorted(str(c) for c in set(raw[CODE_FIELD]) - set(BY_CODE))
    if unknown:
        raise FetchError(f"Response contains untracked contract codes: {unknown}")

    frame = pd.DataFrame(
        {
            "report_date": pd.to_datetime(raw[DATE_FIELD], errors="coerce").dt.normalize(),
            "code": raw[CODE_FIELD].astype(str),
            "symbol": raw[CODE_FIELD].map(lambda code: BY_CODE[code].symbol),
        }
    )
    for source, target in FIELD_MAP.items():
        frame[target] = pd.to_numeric(raw[source], errors="coerce").astype("Int64")
    return frame.sort_values(["code", "report_date"]).reset_index(drop=True)


def _empty_frame() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "report_date": pd.Series(dtype="datetime64[ns]"),
            "code": pd.Series(dtype="object"),
            "symbol": pd.Series(dtype="object"),
            **{column: pd.Series(dtype="Int64") for column in FIELD_MAP.values()},
        }
    )
DOC_EOF

# -------------------------------------------------------------------- TESTS
cat > tests/test_fetcher.py <<'DOC_EOF'
"""Tests for the Socrata fetcher. No network: HTTP is faked."""

from __future__ import annotations

from datetime import date
from typing import Any

import pandas as pd
import pytest
import requests

from src.contracts import all_codes
from src.fetcher import (
    COLUMNS,
    SOCRATA_URL,
    FetchError,
    build_where,
    default_start_date,
    fetch_socrata,
)

XAU = "088691"
ES = "13874A"
JPY = "097741"


class FakeResponse:
    def __init__(
        self,
        payload: Any = None,
        status_code: int = 200,
        text: str = "",
        bad_json: bool = False,
    ) -> None:
        self._payload = payload
        self._bad_json = bad_json
        self.status_code = status_code
        self.text = text

    def json(self) -> Any:
        if self._bad_json:
            raise ValueError("not json")
        return self._payload


class FakeSession:
    def __init__(self, *responses: FakeResponse | Exception) -> None:
        self._responses = list(responses)
        self.calls: list[dict[str, Any]] = []

    def get(
        self,
        url: str,
        *,
        params: dict[str, Any],
        headers: dict[str, str],
        timeout: float,
    ) -> Any:
        self.calls.append(
            {
                "url": url,
                "params": dict(params),
                "headers": dict(headers),
                "timeout": timeout,
            }
        )
        item = self._responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


def make_row(
    code: str,
    report_date: str,
    noncomm_long: int = 100,
    noncomm_short: int = 40,
    comm_long: int = 50,
    comm_short: int = 90,
    open_interest: int = 1000,
) -> dict[str, str]:
    """A Socrata-style row: every value is a string, with extra fields to ignore."""
    return {
        "id": f"{code}-{report_date}",
        "contract_market_name": "IGNORED",
        "report_date_as_yyyy_mm_dd": f"{report_date}T00:00:00.000",
        "cftc_contract_market_code": code,
        "open_interest_all": str(open_interest),
        "noncomm_positions_long_all": str(noncomm_long),
        "noncomm_positions_short_all": str(noncomm_short),
        "comm_positions_long_all": str(comm_long),
        "comm_positions_short_all": str(comm_short),
    }


def test_default_start_date_is_forty_weeks_back() -> None:
    today = date(2026, 11, 18)
    assert (today - default_start_date(today)).days == 280


def test_build_where_lists_codes_and_start_date() -> None:
    where = build_where(all_codes(), date(2026, 2, 10))
    assert all(f"'{code}'" in where for code in all_codes())
    assert "report_date_as_yyyy_mm_dd >= '2026-02-10T00:00:00.000'" in where


@pytest.mark.parametrize("bad", ["12345", "1234567", "09774a", "' OR 1=1 --"])
def test_build_where_rejects_invalid_codes(bad: str) -> None:
    with pytest.raises(ValueError):
        build_where([bad], date(2026, 2, 10))


def test_fetch_returns_sorted_normalized_frame() -> None:
    rows = [
        make_row(XAU, "2026-11-10", noncomm_long=200, noncomm_short=50),
        make_row(ES, "2026-11-10"),
        make_row(XAU, "2026-11-03"),
    ]
    session = FakeSession(FakeResponse(rows))
    frame = fetch_socrata(date(2026, 2, 10), session=session)

    assert list(frame.columns) == COLUMNS
    assert list(frame["symbol"]) == ["XAU", "XAU", "ES"]
    assert list(frame["code"]) == [XAU, XAU, ES]
    assert pd.api.types.is_datetime64_any_dtype(frame["report_date"])
    assert frame["report_date"].iloc[0] == pd.Timestamp("2026-11-03")
    assert frame["noncomm_long"].iloc[1] == 200
    assert str(frame["noncomm_long"].dtype) == "Int64"


def test_leading_zeros_in_codes_are_preserved() -> None:
    session = FakeSession(FakeResponse([make_row(JPY, "2026-11-10")]))
    frame = fetch_socrata(date(2026, 2, 10), session=session)
    assert frame["code"].iloc[0] == "097741"


def test_request_shape() -> None:
    session = FakeSession(FakeResponse([]))
    fetch_socrata(date(2026, 2, 10), session=session)
    call = session.calls[0]
    assert call["url"] == SOCRATA_URL
    assert call["timeout"] > 0
    assert call["params"]["$offset"] == 0
    assert "$where" in call["params"] and "$order" in call["params"]


def test_pages_until_a_short_page() -> None:
    page_one = [make_row(XAU, "2026-11-03"), make_row(XAU, "2026-11-10")]
    page_two = [make_row(ES, "2026-11-10")]
    session = FakeSession(FakeResponse(page_one), FakeResponse(page_two))
    frame = fetch_socrata(date(2026, 2, 10), session=session, page_size=2)

    assert len(frame) == 3
    assert [call["params"]["$offset"] for call in session.calls] == [0, 2]
    assert all(call["params"]["$limit"] == 2 for call in session.calls)


def test_empty_result_gives_empty_frame_with_columns() -> None:
    session = FakeSession(FakeResponse([]))
    frame = fetch_socrata(date(2026, 2, 10), session=session)
    assert frame.empty
    assert list(frame.columns) == COLUMNS


def test_missing_value_becomes_na() -> None:
    complete = make_row(XAU, "2026-11-03")
    incomplete = make_row(XAU, "2026-11-10")
    del incomplete["comm_positions_short_all"]
    session = FakeSession(FakeResponse([complete, incomplete]))
    frame = fetch_socrata(date(2026, 2, 10), session=session)
    assert frame["comm_short"].isna().sum() == 1
    assert frame["comm_short"].iloc[0] == 90


def test_http_error_raises_fetch_error() -> None:
    session = FakeSession(FakeResponse(status_code=500, text="server broke"))
    with pytest.raises(FetchError, match="HTTP 500"):
        fetch_socrata(date(2026, 2, 10), session=session)


def test_network_error_raises_fetch_error() -> None:
    session = FakeSession(requests.ConnectionError("boom"))
    with pytest.raises(FetchError, match="Could not reach"):
        fetch_socrata(date(2026, 2, 10), session=session)


def test_invalid_json_raises_fetch_error() -> None:
    session = FakeSession(FakeResponse(bad_json=True))
    with pytest.raises(FetchError, match="invalid JSON"):
        fetch_socrata(date(2026, 2, 10), session=session)


def test_unexpected_shape_raises_fetch_error() -> None:
    session = FakeSession(FakeResponse({"error": True}))
    with pytest.raises(FetchError, match="unexpected"):
        fetch_socrata(date(2026, 2, 10), session=session)


def test_missing_columns_error_lists_what_was_received() -> None:
    row = make_row(XAU, "2026-11-10")
    del row["comm_positions_long_all"]
    session = FakeSession(FakeResponse([row]))
    with pytest.raises(FetchError, match="missing expected columns") as info:
        fetch_socrata(date(2026, 2, 10), session=session)
    assert "comm_positions_long_all" in str(info.value)
    assert "open_interest_all" in str(info.value)


def test_untracked_code_raises_fetch_error() -> None:
    session = FakeSession(FakeResponse([make_row("999999", "2026-11-10")]))
    with pytest.raises(FetchError, match="untracked"):
        fetch_socrata(date(2026, 2, 10), session=session)


def test_app_token_argument_is_sent(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SOCRATA_APP_TOKEN", raising=False)
    session = FakeSession(FakeResponse([]))
    fetch_socrata(date(2026, 2, 10), session=session, app_token="abc")
    assert session.calls[0]["headers"]["X-App-Token"] == "abc"


def test_app_token_falls_back_to_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SOCRATA_APP_TOKEN", "from-env")
    session = FakeSession(FakeResponse([]))
    fetch_socrata(date(2026, 2, 10), session=session)
    assert session.calls[0]["headers"]["X-App-Token"] == "from-env"


def test_no_token_means_no_header(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SOCRATA_APP_TOKEN", raising=False)
    session = FakeSession(FakeResponse([]))
    fetch_socrata(date(2026, 2, 10), session=session)
    assert session.calls[0]["headers"] == {}
DOC_EOF

# ---------------------------------------------------------------- DECISIONS
python3 - <<'PY'
from pathlib import Path

path = Path("docs/DECISIONS.md")
text = path.read_text()

text = text.replace(
    "| D-006 | Python with `requests`, `pandas` and `pytest`; flat modules in `src/` | Proposed |",
    "| D-006 | Python with `requests`, `pandas` and `pytest`; flat modules in `src/` | Accepted |",
)
text = text.replace("## D-006: Tooling (proposed)", "## D-006: Tooling")
text = text.replace("**Proposal:** ", "**Decision:** ")
text = text.replace(
    "**Status:** Proposed. Confirm or change before Milestone 2.",
    "**Status:** Accepted at the start of Milestone 2.",
)

row_d007 = "| D-007 | How the SQLite ledger persists between GitHub Actions runs | Open |\n"
if "| D-008 |" not in text:
    text = text.replace(
        row_d007,
        row_d007 + "| D-008 | The fetcher pulls 40 weeks of history by default | Accepted |\n",
    )

d008 = """## D-008: Fetch window

**Context:** A full signal needs at least 27 weeks of history (D-001). Holiday delays or missing weeks can leave gaps.

**Decision:** The fetcher pulls 40 weeks of history by default, a buffer of 13 weeks. The window is a function parameter, not a strategy rule.

**Consequences:** The validator (Milestone 2) reports contracts that still have fewer than 27 usable weeks.
"""
if "## D-008" not in text:
    text = text.rstrip("\n") + "\n\n" + d008

path.write_text(text)
PY

echo
echo "Day 3 files written:"
echo "  src/fetcher.py  tests/test_fetcher.py  docs/DECISIONS.md (D-006 accepted, D-008 added)"
echo
echo "Next: source .venv/bin/activate && pytest"
