"""使用完整用户 DDL 与独立 SQL 读取验证真实 PostgreSQL。"""

from decimal import Decimal

import psycopg
import pytest

from mineral_pg.repository import MineralRepository

pytestmark = pytest.mark.integration
BASE = ("FYP14_BASE", "FYP15_BASE")


async def test_periods_are_actual_dictionary(repository):
    """示例年份不覆盖字典的真实基期。"""
    rows = (await repository.list_periods())["rows"]
    periods = {row["period_code"]: row for row in rows}
    assert periods["FYP14_BASE"]["start_year"] == periods["FYP14_BASE"]["end_year"] == 2020
    assert periods["FYP15_BASE"]["start_year"] == periods["FYP15_BASE"]["end_year"] == 2025


async def test_minerals_paginate(repository):
    """发现标准名称并保持确定分页。"""
    first = await repository.list_minerals(limit=1)
    second = await repository.list_minerals(limit=1, offset=1)
    assert first["has_more"] and second["has_more"]
    assert first["rows"][0]["mineral_id"] == "M01"
    assert second["rows"][0]["mineral_id"] == "M02"
    assert first["rows"][0]["is_key_mineral"] is True


@pytest.mark.parametrize(
    ("kind", "expected"),
    [
        ("mine", {"total": 5, "appeared": 1, "disappeared": 1, "modified": 2, "unchanged": 1}),
        ("explore_right", {"total": 3, "appeared": 1, "disappeared": 1, "modified": 1, "unchanged": 0}),
        ("mining_right", {"total": 3, "appeared": 1, "disappeared": 1, "modified": 1, "unchanged": 0}),
    ],
)
async def test_stable_identity_not_license(repository, kind, expected):
    """源证号变更不制造新增和缺失；同名不同代理键不合并。"""
    result = await repository.compare_entities(kind, *BASE)
    assert result["summary"] == expected
    modified = [row for row in result["rows"] if row["change"] == "modified"]
    assert modified
    if kind != "mine":
        assert modified[0]["before"]["right_code"].startswith("OLD")
        assert modified[0]["after"]["right_code"].startswith("NEW")
    else:
        renamed = next(row for row in modified if row["entity_id"] == "MN-RENAME")
        assert renamed["before"]["reserves"] == "99999999999999.9998"
        assert renamed["after"]["reserves"] == "99999999999999.9999"


async def test_filter_after_identity_join_and_page_summary(repository):
    """主矿种改变仍是同一实体，页外也返回完整统计。"""
    filtered = await repository.compare_entities("mine", *BASE, mineral_id="M02")
    assert filtered["summary"]["modified"] == 1
    assert filtered["summary"]["appeared"] == 0
    assert filtered["summary"]["unchanged"] == 1
    assert filtered["summary"]["total"] == 2
    changed = next(row for row in filtered["rows"] if row["change"] == "modified")
    assert changed["before"]["mineral_id"] == "M01"
    page = await repository.compare_entities("mine", *BASE, limit=1, offset=99)
    assert page["rows"] == []
    assert page["summary"]["total"] == 5


async def test_reserves_match_independent_sql(repository, database):
    """独立 SQL oracle 与人工确定的差值交叉核验。"""
    result = await repository.compare_reserves(*BASE, mineral_id="M01")
    row = result["rows"][0]
    with psycopg.connect(database["owner"]) as connection:
        delta = connection.execute("""
            SELECT newer.retained_reserves - older.retained_reserves
            FROM fact_mineral_reserve older JOIN fact_mineral_reserve newer USING(mineral_id)
            JOIN dim_period bp ON bp.period_id=older.period_id
            JOIN dim_period ap ON ap.period_id=newer.period_id
            WHERE bp.period_code='FYP14_BASE' AND ap.period_code='FYP15_BASE' AND older.mineral_id='M01'
        """).fetchone()[0]
    assert Decimal(row["delta"]) == delta == Decimal("25.0250")
    assert row["change_percent"] == "25.0000"
    cumulative = await repository.compare_reserves(*BASE, mineral_id="M01", metric="cumulative_reserves")
    assert cumulative["rows"][0]["delta"] == "10.0050"


@pytest.mark.parametrize(
    ("mineral", "status", "delta"),
    [
        ("M02", "unit_mismatch", None),
        ("M03", "missing_to_period", None),
        ("M04", "missing_from_period", None),
        ("M05", "missing_value", None),
        ("M06", "comparable", "0.0001"),
        ("M07", "comparable", "1.0000"),
        ("M08", "unknown_unit", None),
        ("M09", "unknown_unit", None),
        ("M10", "missing_value", None),
    ],
)
async def test_reserve_edge_cases(repository, mineral, status, delta):
    """不混算单位、不把缺期与未填报变成零。"""
    row = (await repository.compare_reserves(*BASE, mineral_id=mineral))["rows"][0]
    assert row["comparison_status"] == status
    assert row["delta"] == delta
    if mineral == "M07":
        assert row["change_percent"] is None


async def test_annual_not_summary_or_capacity(repository, database):
    """年度事实与独立汇总 SQL 相同且排除 stat_year=0。"""
    result = await repository.annual_output("FYP15_BASE", 2024, 2025, "M01")
    assert [(row["stat_year"], row["output_total"]) for row in result["rows"]] == [(2024, "10.1000"), (2025, "20.2000")]
    with psycopg.connect(database["owner"]) as connection:
        expected = connection.execute("""
            SELECT SUM(output_total) FROM fact_mineral_develop
            WHERE mineral_id='M01' AND stat_year IN (2024,2025)
              AND period_id=(SELECT period_id FROM dim_period WHERE period_code='FYP15_BASE')
        """).fetchone()[0]
    assert sum(Decimal(row["output_total"]) for row in result["rows"]) == expected == Decimal("30.3000")
    other_period = await repository.annual_output("FYP14_BASE", 2024, 2024, "M01")
    assert [(row["output_total"], row["output_unit"]) for row in other_period["rows"]] == [("123456.7890", "吨")]
    assert (await repository.annual_output("FYP15_BASE", 2023, 2023, "M01"))["rows"] == []
    all_rows = (await repository.annual_output("FYP15_BASE", 2025, 2025))["rows"]
    assert next(row for row in all_rows if row["mineral_id"] == "M03")["data_status"] == "missing_value"
    assert next(row for row in all_rows if row["mineral_id"] == "M04")["data_status"] == "unknown_unit"


@pytest.mark.parametrize(
    ("from_period", "to_period"),
    [
        ("FYP14_BASE", "FYP14_BASE"),
        ("FYP14_PLAN", "FYP15_BASE"),
        ("2021", "FYP15_BASE"),
        ("x'; DROP TABLE dim_period;--", "FYP15_BASE"),
        ("UNKNOWN_BASE", "FYP15_BASE"),
    ],
)
async def test_invalid_period_not_empty_result(repository, from_period, to_period):
    """无效条件或注入文本不能伪装成正常空结果。"""
    with pytest.raises(ValueError):
        await repository.compare_reserves(from_period, to_period)


async def test_readonly_transaction_and_role(repository, database):
    """读取数据库自身状态证明只读、超时及最小授权。"""
    async with repository.connection() as connection:
        state = await (
            await connection.execute(
                "SELECT current_setting('transaction_read_only') AS ro, current_setting('statement_timeout') AS timeout"
            )
        ).fetchone()
        assert state == {"ro": "on", "timeout": "10s"}
        privileges = await (
            await connection.execute("SELECT has_table_privilege(current_user, 'fact_mine', 'INSERT') AS can_write")
        ).fetchone()
        assert privileges["can_write"] is False
        with pytest.raises(psycopg.errors.ReadOnlySqlTransaction):
            await connection.execute("DELETE FROM fact_mine")
    with pytest.raises(PermissionError, match="超级用户"):
        async with MineralRepository(database["owner"]).connection():
            pytest.fail("owner role must not be allowed")


async def test_real_postgres_timeout_is_sanitized(repository):
    """数据库实际取消语句后，工具边界只返回稳定超时错误。"""
    from mcp.server.fastmcp.exceptions import ToolError

    from mineral_pg.server import database_result

    async def slow_query():
        """使用局部测试时限产生 PostgreSQL QueryCanceled。"""
        async with repository.connection() as connection:
            await connection.execute("SET LOCAL statement_timeout = '10ms'")
            await connection.execute("SELECT pg_sleep(0.1)")

    with pytest.raises(ToolError, match="query_timeout") as exception:
        await database_result(slow_query())
    assert "pg_sleep" not in str(exception.value)


async def test_server_enforces_readonly_without_role_default(repository, database):
    """具有写权限且默认可写的普通角色仍被服务事务限制。"""
    from psycopg import sql

    role = sql.Identifier(database["role"])
    with psycopg.connect(database["owner"], autocommit=True) as admin:
        admin.execute(sql.SQL("ALTER ROLE {} SET default_transaction_read_only=off").format(role))
        admin.execute(sql.SQL("GRANT DELETE ON fact_mine TO {}").format(role))
        try:
            with psycopg.connect(database["readonly"]) as direct:
                assert direct.execute("SHOW transaction_read_only").fetchone()[0] == "off"
                assert direct.execute("SELECT has_table_privilege(current_user, 'fact_mine', 'DELETE')").fetchone()[0]
            async with repository.connection() as connection:
                state = await (await connection.execute("SELECT current_setting('transaction_read_only') AS ro")).fetchone()
                assert state["ro"] == "on"
                with pytest.raises(psycopg.errors.ReadOnlySqlTransaction):
                    await connection.execute("DELETE FROM fact_mine WHERE false")
        finally:
            admin.execute(sql.SQL("REVOKE DELETE ON fact_mine FROM {}").format(role))
            admin.execute(sql.SQL("ALTER ROLE {} SET default_transaction_read_only=on").format(role))


async def test_bypassrls_role_rejected_even_without_superuser(repository, database):
    """普通登录角色具有 BYPASSRLS 时也不能服务业务查询。"""
    from psycopg import sql

    with psycopg.connect(database["admin"], autocommit=True) as admin:
        admin.execute(sql.SQL("ALTER ROLE {} BYPASSRLS").format(sql.Identifier(database["role"])))
        try:
            with pytest.raises(PermissionError, match="BYPASSRLS"):
                await repository.list_periods()
        finally:
            admin.execute(sql.SQL("ALTER ROLE {} NOBYPASSRLS").format(sql.Identifier(database["role"])))


@pytest.mark.parametrize(("limit", "offset"), [(0, 0), (201, 0), (1, -1), (1, 100001), (True, 0)])
async def test_repository_rejects_unbounded_pages(repository, limit, offset):
    """内部调用同样不能绕过返回量边界。"""
    with pytest.raises(ValueError, match="分页"):
        await repository.list_minerals(limit=limit, offset=offset)


async def test_repository_rejects_dynamic_identifiers(repository):
    """固定白名单防止其他调用路径构造动态表列。"""
    with pytest.raises(ValueError, match="实体类型"):
        await repository.compare_entities("mine;DROP", *BASE)
    with pytest.raises(ValueError, match="储量口径"):
        await repository.compare_reserves(*BASE, metric="retained_reserves;DROP")
