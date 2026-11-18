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
