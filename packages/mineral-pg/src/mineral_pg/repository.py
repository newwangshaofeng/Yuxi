"""以固定 SQL 读取用户提供的矿产规划 Schema。"""

import json
from contextlib import asynccontextmanager
from decimal import Decimal
from functools import partial
from typing import Any, Literal

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import set_json_loads

from mineral_pg.results import reserve_change, serialize

EntityKind = Literal["mine", "explore_right", "mining_right"]
ReserveMetric = Literal["retained_reserves", "cumulative_reserves"]

ENTITY_COLUMNS = {
    "mine": (
        "fact_mine",
        "mine_id",
        (
            "mine_code",
            "mine_name",
            "mineral_id",
            "admin_region",
            "reserve_unit",
            "reserves",
            "develop_status",
            "mining_scale",
            "mining_method",
            "output_unit",
            "design_capacity",
            "output",
            "output_value",
            "mining_recovery_rate",
            "dressing_recovery_rate",
            "comprehensive_value",
        ),
    ),
    "explore_right": (
        "fact_explore_right",
        "right_id",
        (
            "right_code",
            "holder",
            "project_name",
            "explore_degree",
            "mineral_id",
            "regist_area_km2",
            "map_sheet_no",
            "valid_from",
            "valid_to",
            "right_status",
        ),
    ),
    "mining_right": (
        "fact_mining_right",
        "right_id",
        (
            "right_code",
            "holder",
            "mine_name",
            "economic_type",
            "mineral_id",
            "mining_method",
            "reserve_unit",
            "regist_reserves",
            "production_scale",
            "regist_area_km2",
            "valid_from",
            "valid_to",
            "right_status",
        ),
    ),
}


class MineralRepository:
    """每次调用使用独立只读事务与数据库侧执行时限。"""

    def __init__(self, dsn: str):
        """保留私有连接配置，仅在查询时连接。"""
        self.dsn = dsn

    @asynccontextmanager
    async def connection(self):
        """拒绝超级用户，确保每次查询不写入且读取同一快照。"""
        async with await psycopg.AsyncConnection[dict[str, Any]].connect(
            self.dsn,
            connect_timeout=5,
            row_factory=dict_row,
            options="-c default_transaction_read_only=on -c statement_timeout=10000 -c search_path=public",
        ) as connection:
            set_json_loads(partial(json.loads, parse_float=Decimal), context=connection)
            await connection.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            role = await (await connection.execute("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")).fetchone()
            if role is None or role["rolsuper"] or role["rolbypassrls"]:
                raise PermissionError("业务连接必须使用无超级用户及 BYPASSRLS 权限的只读角色")
            yield connection

    async def list_periods(self) -> dict:
        """列出真实期次，保留基期与规划期的差异。"""
        async with self.connection() as connection:
            rows = await (
                await connection.execute(
                    "SELECT period_code, period_label, period_role, period_type, start_year, end_year "
                    "FROM dim_period ORDER BY start_year, period_code LIMIT 201"
                )
            ).fetchall()
        return {"rows": rows[:200], "truncated": len(rows) > 200}

    async def list_minerals(self, limit: int = 100, offset: int = 0) -> dict:
        """分页读取矿种标准名称与标识，不猜测业务别名。"""
        self._page(limit, offset)
        async with self.connection() as connection:
            rows = await (
                await connection.execute(
                    "SELECT mineral_id, mineral_code, mineral_name, mineral_category, default_unit, is_key_mineral "
                    "FROM dim_mineral ORDER BY mineral_id LIMIT %s OFFSET %s",
                    (limit + 1, offset),
                )
            ).fetchall()
        return {"rows": rows[:limit], "has_more": len(rows) > limit, "offset": offset}

    async def compare_entities(
        self,
        entity_kind: EntityKind,
        from_period: str,
        to_period: str,
        mineral_id: str | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> dict:
        """按跨期代理键比较成员及属性，不将快照缺失解释为注销。"""
        self._page(limit, offset)
        if entity_kind not in ENTITY_COLUMNS:
            raise ValueError("不支持的实体类型")
        table, key, columns = ENTITY_COLUMNS[entity_kind]

        # Identifiers originate only in the fixed schema map, never in model input.
        def attributes(alias: str) -> str:
            """仅投影当前实体的白名单属性。"""
            return "jsonb_build_object(" + ", ".join(f"'{column}', {alias}.{column}" for column in columns) + ")"

        before, after = attributes("b"), attributes("a")
        mineral_filter = "(%s::text IS NULL OR b.mineral_id = %s OR a.mineral_id = %s)"
        if entity_kind == "mine":
            mineral_filter = """(%s::text IS NULL OR b.mineral_id = %s OR a.mineral_id = %s OR EXISTS (
                SELECT 1 FROM fact_mine_mineral mm WHERE mm.mineral_id = %s AND (
                    (mm.period_id = b.period_id AND mm.mine_id = b.mine_id) OR
                    (mm.period_id = a.period_id AND mm.mine_id = a.mine_id)
                )
            ))"""
        cte = f"""
            WITH b AS (SELECT * FROM {table} WHERE period_id = %s),
                 a AS (SELECT * FROM {table} WHERE period_id = %s),
                 compared AS (
                SELECT COALESCE(b.{key}, a.{key}) AS entity_id,
                       CASE WHEN b.{key} IS NOT NULL THEN {before} END AS before,
                       CASE WHEN a.{key} IS NOT NULL THEN {after} END AS after,
                       CASE WHEN b.{key} IS NULL THEN 'appeared'
                            WHEN a.{key} IS NULL THEN 'disappeared'
                            WHEN {before} IS DISTINCT FROM {after} THEN 'modified'
                            ELSE 'unchanged' END AS change
                FROM b FULL OUTER JOIN a ON b.{key} = a.{key}
                WHERE {mineral_filter}
            )
        """
        async with self.connection() as connection:
            periods = await self._comparison_periods(connection, from_period, to_period)
            await self._mineral(connection, mineral_id)
            params = (periods[0]["period_id"], periods[1]["period_id"], mineral_id, mineral_id, mineral_id)
            if entity_kind == "mine":
                params += (mineral_id,)
            summary = await (
                await connection.execute(
                    cte + " SELECT count(*) AS total, count(*) FILTER (WHERE change='appeared') AS appeared, "
                    "count(*) FILTER (WHERE change='disappeared') AS disappeared, "
                    "count(*) FILTER (WHERE change='modified') AS modified, "
                    "count(*) FILTER (WHERE change='unchanged') AS unchanged FROM compared",
                    params,
                )
            ).fetchone()
            rows = await (
                await connection.execute(
                    cte + " SELECT * FROM compared ORDER BY entity_id LIMIT %s OFFSET %s", (*params, limit + 1, offset)
                )
            ).fetchall()
        return serialize(
            {
                "entity_kind": entity_kind,
                "from_period": periods[0],
                "to_period": periods[1],
                "mineral_id": mineral_id,
                "summary": summary,
                "rows": rows[:limit],
                "has_more": len(rows) > limit,
                "offset": offset,
                "source_table": table,
                "identity_basis": key,
                "mineral_filter_basis": "任一期主矿种或关联矿种" if entity_kind == "mine" else "任一期登记矿种",
                "scope_note": (
                    "按已正确跨期复用的代理键比较快照；出现/缺失不等于新设/注销，不自动推断整合、分立或探转采；"
                    "变化分类仅比较所列属性，不比较几何或关联明细变化。"
                ),
            }
        )

    async def compare_reserves(
        self,
        from_period: str,
        to_period: str,
        mineral_id: str | None = None,
        metric: ReserveMetric = "retained_reserves",
        limit: int = 100,
        offset: int = 0,
    ) -> dict:
        """对比储量源表，不与矿区明细重复相加。"""
        self._page(limit, offset)
        if metric not in ("retained_reserves", "cumulative_reserves"):
            raise ValueError("不支持的储量口径")
        async with self.connection() as connection:
            periods = await self._comparison_periods(connection, from_period, to_period)
            await self._mineral(connection, mineral_id)
            rows = await (
                await connection.execute(
                    f"""
                WITH b AS (SELECT * FROM fact_mineral_reserve WHERE period_id = %s),
                     a AS (SELECT * FROM fact_mineral_reserve WHERE period_id = %s)
                SELECT m.mineral_id, m.mineral_name, b.id IS NOT NULL AS from_present,
                       a.id IS NOT NULL AS to_present, b.{metric} AS from_value, a.{metric} AS to_value,
                       b.reserve_unit AS from_unit, a.reserve_unit AS to_unit
                FROM b FULL OUTER JOIN a ON b.mineral_id = a.mineral_id
                JOIN dim_mineral m ON m.mineral_id = COALESCE(b.mineral_id, a.mineral_id)
                WHERE (%s::text IS NULL OR m.mineral_id = %s)
                ORDER BY m.mineral_id LIMIT %s OFFSET %s
            """,
                    (periods[0]["period_id"], periods[1]["period_id"], mineral_id, mineral_id, limit + 1, offset),
                )
            ).fetchall()
        return {
            "from_period": periods[0],
            "to_period": periods[1],
            "metric": metric,
            "rows": [reserve_change(row) for row in rows[:limit]],
            "has_more": len(rows) > limit,
            "offset": offset,
            "source_table": "fact_mineral_reserve",
            "mineral_id": mineral_id,
            "scope_note": "全域矿种汇总；不提供此表不存在的行政区筛选；不合计不同矿种，不换算不一致或未知单位；缺期不视为零。",
        }

    async def annual_output(
        self,
        period_code: str,
        start_year: int,
        end_year: int,
        mineral_id: str | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> dict:
        """读取具体年度产量，排除期次汇总与设计产能。"""
        self._page(limit, offset)
        if not 1900 <= start_year <= end_year <= 2200:
            raise ValueError("年度范围必须满足 1900 ≤ 起年 ≤ 止年 ≤ 2200")
        async with self.connection() as connection:
            period = await self._period(connection, period_code)
            await self._mineral(connection, mineral_id)
            rows = await (
                await connection.execute(
                    """
                SELECT d.stat_year, m.mineral_id, m.mineral_name, d.output_unit,
                       d.output_total, d.output_large, d.output_medium, d.output_small,
                       d.mine_count_total, d.output_value_total,
                       CASE WHEN d.output_total IS NULL THEN 'missing_value'
                            WHEN NULLIF(btrim(d.output_unit), '') IS NULL THEN 'unknown_unit'
                            ELSE 'reported' END AS data_status
                FROM fact_mineral_develop d JOIN dim_mineral m USING (mineral_id)
                WHERE d.period_id = %s AND d.stat_year > 0 AND d.stat_year BETWEEN %s AND %s
                  AND (%s::text IS NULL OR d.mineral_id = %s)
                ORDER BY d.stat_year, m.mineral_id LIMIT %s OFFSET %s
            """,
                    (period["period_id"], start_year, end_year, mineral_id, mineral_id, limit + 1, offset),
                )
            ).fetchall()
        return serialize(
            {
                "period": period,
                "start_year": start_year,
                "end_year": end_year,
                "mineral_id": mineral_id,
                "rows": rows[:limit],
                "has_more": len(rows) > limit,
                "offset": offset,
                "source_table": "fact_mineral_develop",
                "metric": "output_total",
                "output_value_unit": "万元",
                "scope_note": "只返回实际存在的年度行；stat_year=0 不作年度值，缺年不补零；产量不以设计产能代替，不跨矿种相加。",
            }
        )

    async def _comparison_periods(self, connection, from_code: str, to_code: str) -> list[dict]:
        """解析两个不同的现状基期。"""
        if from_code == to_code:
            raise ValueError("对比必须选择两个不同基期")
        return [await self._period(connection, from_code), await self._period(connection, to_code)]

    async def _period(self, connection, code: str) -> dict:
        """只接受字典中年份明确的单年基期。"""
        row = await (
            await connection.execute(
                "SELECT period_id, period_code, period_label, period_role, period_type, start_year, end_year "
                "FROM dim_period WHERE period_code = %s",
                (code,),
            )
        ).fetchone()
        if row is None:
            raise ValueError("期次不存在；请先调用 list_periods")
        if (
            row["period_role"] != "base"
            or row["period_type"] != "status"
            or row["start_year"] is None
            or row["start_year"] != row["end_year"]
        ):
            raise ValueError("本工具仅接受现状基期，不将规划目标期作为实际值")
        return row

    async def _mineral(self, connection, mineral_id: str | None) -> None:
        """校验显式指定的矿种存在。"""
        if mineral_id is not None:
            row = await (await connection.execute("SELECT mineral_id FROM dim_mineral WHERE mineral_id = %s", (mineral_id,))).fetchone()
            if row is None:
                raise ValueError("矿种不存在；请先调用 list_minerals")

    @staticmethod
    def _page(limit: int, offset: int) -> None:
        """约束结果上限与可访问偏移。"""
        if type(limit) is not int or type(offset) is not int or not 1 <= limit <= 200 or not 0 <= offset <= 100000:
            raise ValueError("分页要求 1 ≤ limit ≤ 200 且 0 ≤ offset ≤ 100000")
