"""构造精确数值与显式口径的查询结果。"""

from datetime import date, datetime
from decimal import Decimal
from typing import Any


def serialize(value: Any) -> Any:
    """以十进制字符串保留数值，不经过二进制浮点。"""
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    if isinstance(value, dict):
        return {key: serialize(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [serialize(item) for item in value]
    return value


def reserve_change(row: dict) -> dict:
    """只有两期均存在且单位明确一致时计算变化。"""
    row = dict(row)
    before, after = row["from_value"], row["to_value"]
    if not row["from_present"]:
        status = "missing_from_period"
    elif not row["to_present"]:
        status = "missing_to_period"
    elif before is None or after is None:
        status = "missing_value"
    elif not (row["from_unit"] or "").strip() or not (row["to_unit"] or "").strip():
        status = "unknown_unit"
    elif row["from_unit"] != row["to_unit"]:
        status = "unit_mismatch"
    else:
        status = "comparable"
    delta = after - before if status == "comparable" else None
    rate = None
    if delta is not None and before != 0:
        rate = (delta / before * 100).quantize(Decimal("0.0001"))
    row.update(comparison_status=status, delta=delta, change_percent=rate)
    return serialize(row)
