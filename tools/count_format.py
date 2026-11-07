"""Format count labels while retaining their exact values and lower bounds.

The convention follows the deployed GitHub star counter reviewed 7 Nov 2026:
https://github.githubassets.com/assets/code-view-5d65cb0f8c6bfda9.js
T/Q extend that profile for Asm's safe-integer range. They are not observed
GitHub repository-count evidence. No locale or floating-point rounding is used.
SPDX-License-Identifier: AGPL-3.0-or-later
"""

MAX_COUNT = 9007199254740991
SUFFIXES = ("", "k", "M", "B", "T", "Q")


def _value(value: int) -> int:
    if type(value) is not int or not 0 <= value <= MAX_COUNT:
        raise ValueError("count must be a nonnegative safe integer")
    return value


def compact_count(value: int, *, lower_bound=False) -> str:
    """Use one decimal, trimming zeroes; lower bounds round downward.

    Select the unit before rounding. Use integer k/M between 100 and 1000
    units, retaining GitHub's 1000k/1000M rollover rather than changing units.
    """
    value = _value(value)
    if type(lower_bound) is not bool:
        raise ValueError("lower bound mode must be boolean")
    if value < 1000:
        return str(value)
    unit, index = 1000, 1
    while value >= unit * 1000 and index < len(SUFFIXES) - 1:
        unit *= 1000
        index += 1
    precision = 0 if 100000 <= value < 1000000 or 100000000 <= value < 1000000000 else 1
    scale = 10 ** precision
    rounded = (value * scale + (0 if lower_bound else unit // 2)) // unit
    whole, fraction = divmod(rounded, scale)
    text = str(whole) + ("." + str(fraction) if fraction else "")
    return text + SUFFIXES[index]


def exact_count(value: int) -> str:
    """Return the exact grouped integer for titles and data tables."""
    return f"{_value(value):,}"


def count_html(value: int, *, lower_bound=False) -> str:
    """Return compact visible text and one exact accessible count.

    Null is not a zero. Callers retain their own unavailable state.
    The title and accessible text preserve the ≥ qualification when present.
    """
    compact = compact_count(value, lower_bound=lower_bound)
    prefix = "≥ " if lower_bound else ""
    exact = prefix + exact_count(value)
    return ('<span class="compact-count" title="' + exact + '"><span aria-hidden="true">' + prefix + compact +
            '</span><span class="sr-only">' + exact + '</span></span>')
