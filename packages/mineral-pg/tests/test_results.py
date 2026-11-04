"""直接验证业务数值，不以工具调用次数代替结果。"""

from datetime import date
from decimal import Decimal

import pytest

from mineral_pg.results import reserve_change, serialize


@pytest.mark.parametrize(
    ("before", "after", "delta", "percent"),
    [
        ("100.1000", "125.1250", "25.0250", "25.0000"),
        ("0.0000", "1.0000", "1.0000", None),
        ("99999999999999.9998", "99999999999999.9999", "0.0001", "0.0000"),
        ("10.0000", "7.0000", "-3.0000", "-30.0000"),
    ],
)
def test_exact_changes(before, after, delta, percent):
    """精确差值、零分母及负向变化保持定义。"""
    row = reserve_change(
        {
            "from_present": True,
            "to_present": True,
            "from_unit": "吨",
            "to_unit": "吨",
            "from_value": Decimal(before),
            "to_value": Decimal(after),
        }
    )
    assert row["delta"] == delta
    assert row["change_percent"] == percent
    assert row["comparison_status"] == "comparable"


@pytest.mark.parametrize(
    ("patch", "status"),
    [
        ({"from_present": False}, "missing_from_period"),
        ({"to_present": False}, "missing_to_period"),
        ({"from_value": None}, "missing_value"),
        ({"to_value": None}, "missing_value"),
        ({"to_unit": "万吨"}, "unit_mismatch"),
        ({"from_unit": None}, "unknown_unit"),
        ({"from_unit": " "}, "unknown_unit"),
        ({"to_unit": ""}, "unknown_unit"),
    ],
)
def test_noncomparable_is_not_zero(patch, status):
    """不具备可比条件时禁止计算差值。"""
    row = {
        "from_present": True,
        "to_present": True,
        "from_unit": "吨",
        "to_unit": "吨",
        "from_value": Decimal("1.0000"),
        "to_value": Decimal("2.0000"),
        **patch,
    }
    result = reserve_change(row)
    assert result["comparison_status"] == status
    assert result["delta"] is result["change_percent"] is None


def test_serialization_retains_nested_decimal_and_date():
    """JSON 对象里的小数和日期也保持精度及格式。"""
    assert serialize({"rows": [{"value": Decimal("0.0001"), "date": date(2025, 1, 1)}]}) == {
        "rows": [{"value": "0.0001", "date": "2025-01-01"}]
    }
