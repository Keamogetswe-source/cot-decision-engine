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
