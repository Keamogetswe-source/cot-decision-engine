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
