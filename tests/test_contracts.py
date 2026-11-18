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
