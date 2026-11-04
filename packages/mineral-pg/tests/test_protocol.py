"""真实 HTTP 与 MCP client 验证工具事实、认证及参数边界。"""

import asyncio

import httpx
import psycopg
import pytest
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from psycopg import sql

from mineral_pg.server import BearerAuth


@pytest.mark.parametrize("token", ["", "short", "x" * 31, "令" * 32, "a " * 32])
def test_weak_or_invalid_token_rejected(token):
    """部署令牌必须满足长度与编码边界。"""
    with pytest.raises(ValueError, match="MINERAL_PG_TOKEN"):
        BearerAuth(None, token)


@pytest.mark.parametrize("authorization", [None, "Basic wrong", "Bearer wrong", "Bearer", "Bearer 中文"])
async def test_http_rejects_auth_before_database(http_server, authorization):
    """未认证请求在协议之前返回明确失败。"""
    headers = {} if authorization is None else {"Authorization": authorization.encode("utf-8")}
    async with httpx.AsyncClient() as client:
        response = await client.post(http_server["url"], headers=headers, json={})
    assert response.status_code == 401
    assert response.json() == {"error": "unauthorized"}


async def test_duplicate_authorization_rejected(http_server):
    """多个认证头不能产生含糊认证。"""
    async with httpx.AsyncClient() as client:
        response = await client.post(
            http_server["url"], headers=[("Authorization", "Bearer " + http_server["token"]), ("Authorization", "Bearer wrong")], json={}
        )
    assert response.status_code == 401


@pytest.mark.parametrize(("header", "value", "status"), [("Host", "attacker.invalid", 421), ("Origin", "https://attacker.invalid", 403)])
async def test_mcp_rejects_untrusted_host_and_origin(http_server, header, value, status):
    """持有令牌也不能绕过部署 Host 与 Origin 边界。"""
    headers = {"Authorization": "Bearer " + http_server["token"], header: value}
    async with httpx.AsyncClient() as client:
        response = await client.post(http_server["url"], headers=headers, json={})
    assert response.status_code == status


async def test_mcp_discovery_and_three_queries(http_server):
    """验证握手、schema、三个业务事实及只读声明。"""
    async with httpx.AsyncClient(headers={"Authorization": "Bearer " + http_server["token"]}) as client:
        async with streamable_http_client(http_server["url"], http_client=client) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = (await session.list_tools()).tools
                assert {tool.name for tool in tools} == {
                    "list_periods",
                    "list_minerals",
                    "compare_entities",
                    "compare_reserves",
                    "annual_output",
                }
                assert all(tool.annotations.readOnlyHint for tool in tools)
                assert all(tool.inputSchema["additionalProperties"] is False for tool in tools)
                periods = await session.call_tool("list_periods")
                assert not periods.isError
                assert periods.structuredContent["rows"][0]["start_year"] == 2020
                minerals = await session.call_tool("list_minerals")
                assert not minerals.isError
                assert minerals.structuredContent["rows"][0]["mineral_id"] == "M01"
                args = {"from_period": "FYP14_BASE", "to_period": "FYP15_BASE", "mineral_id": "M01"}
                reserves = await session.call_tool("compare_reserves", args)
                assert not reserves.isError
                assert reserves.structuredContent["rows"][0]["delta"] == "25.0250"
                entities = await session.call_tool("compare_entities", {**args, "entity_kind": "mining_right"})
                assert not entities.isError
                assert entities.structuredContent["summary"]["modified"] == 1
                annual = await session.call_tool(
                    "annual_output", {"period_code": "FYP15_BASE", "start_year": 2024, "end_year": 2025, "mineral_id": "M01"}
                )
                assert not annual.isError
                assert [row["output_total"] for row in annual.structuredContent["rows"]] == ["10.1000", "20.2000"]


@pytest.mark.parametrize(
    ("name", "arguments"),
    [
        ("list_periods", {"sql": "DROP TABLE dim_period"}),
        ("list_minerals", {"limit": 201}),
        ("list_minerals", {"limit": 0}),
        ("list_minerals", {"limit": True}),
        ("list_minerals", {"limit": "100"}),
        ("list_minerals", {"offset": -1}),
        ("list_minerals", {"offset": 100001}),
        ("compare_entities", {"entity_kind": "mine;DROP", "from_period": "FYP14_BASE", "to_period": "FYP15_BASE"}),
        ("compare_reserves", {"from_period": "FYP14_BASE", "to_period": "FYP15_BASE", "admin_region": "341800"}),
        ("compare_reserves", {"from_period": "FYP14_BASE", "to_period": "FYP15_BASE", "metric": "reserves;DROP"}),
        ("compare_reserves", {"from_period": "FYP14_BASE", "to_period": "FYP15_PLAN"}),
        ("compare_reserves", {"from_period": "FYP14_BASE", "to_period": "FYP15_BASE", "mineral_id": "' OR 1=1--"}),
        ("compare_reserves", {"from_period": "FYP14_BASE", "to_period": "FYP15_BASE", "mineral_id": "x" * 33}),
        ("compare_reserves", {"from_period": "x" * 17, "to_period": "FYP15_BASE"}),
        ("annual_output", {"period_code": "FYP15_BASE", "start_year": 0, "end_year": 2025}),
        ("annual_output", {"period_code": "FYP15_BASE", "start_year": 2026, "end_year": 2025}),
        ("annual_output", {"period_code": "FYP15_BASE", "start_year": 2025, "end_year": 2201}),
        ("annual_output", {"period_code": "FYP15_BASE"}),
        ("execute_sql", {"sql": "SELECT * FROM fact_mine"}),
    ],
)
async def test_mcp_invalid_inputs_are_errors_not_empty(http_server, name, arguments):
    """从真实协议拒绝无效条件与注入，不静默忽略过滤条件。"""
    async with httpx.AsyncClient(headers={"Authorization": "Bearer " + http_server["token"]}) as client:
        async with streamable_http_client(http_server["url"], http_client=client) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool(name, arguments)
                assert result.isError
                assert result.structuredContent is None


async def test_repeat_and_concurrent_calls_return_same_facts(http_server):
    """重复与并发调用均须返回相同业务事实，非仅 HTTP 成功。"""
    async with httpx.AsyncClient(headers={"Authorization": "Bearer " + http_server["token"]}) as client:
        async with streamable_http_client(http_server["url"], http_client=client) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                args = {"from_period": "FYP14_BASE", "to_period": "FYP15_BASE", "mineral_id": "M06"}
                results = []
                for _ in range(5):
                    results.append(await session.call_tool("compare_reserves", args))
                results.extend(await asyncio.gather(*(session.call_tool("compare_reserves", args) for _ in range(10))))
                assert all(not result.isError for result in results)
                values = [result.structuredContent for result in results]
                assert all(value == values[0] for value in values)
                assert values[0]["rows"][0]["delta"] == "0.0001"


@pytest.mark.parametrize(
    ("period_type", "period_role", "start_year", "end_year"),
    [("status", "plan", 2030, 2030), ("plan", "base", 2030, 2030), ("status", "base", 2030, 2031)],
)
async def test_period_guards_are_independently_enforced(database, repository, http_server, period_type, period_role, start_year, end_year):
    """分别证明类型、角色和单年约束，其他约束不能替代目标 guard。"""
    with psycopg.connect(database["owner"], autocommit=True) as owner:
        owner.execute(
            "INSERT INTO dim_period(period_id,period_code,period_label,period_type,period_role,cycle_code,cycle_name,start_year,end_year) "
            "VALUES ('INVALID_TEST','INVALID_TEST','测试期次约束',%s,%s,'INVALID_TEST','测试周期',%s,%s)",
            (period_type, period_role, start_year, end_year),
        )
        try:
            with pytest.raises(ValueError, match="现状基期"):
                await repository.compare_reserves("FYP14_BASE", "INVALID_TEST", "M01")
            async with httpx.AsyncClient(headers={"Authorization": "Bearer " + http_server["token"]}) as client:
                async with streamable_http_client(http_server["url"], http_client=client) as (read, write, _):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        result = await session.call_tool(
                            "annual_output", {"period_code": "INVALID_TEST", "start_year": 2030, "end_year": 2030}
                        )
                        assert result.isError
                        assert "invalid_parameters" in result.content[0].text
                        assert "现状基期" in result.content[0].text
        finally:
            owner.execute("DELETE FROM dim_period WHERE period_code='INVALID_TEST'")


@pytest.mark.parametrize("role_attribute", ["SUPERUSER", "BYPASSRLS"])
async def test_privileged_deployment_is_database_unavailable(database, http_server, role_attribute):
    """配置错误由管理员修复，不冒充用户查询条件错误。"""
    role = sql.Identifier(database["role"])
    with psycopg.connect(database["admin"], autocommit=True) as admin:
        admin.execute(sql.SQL("ALTER ROLE {} {}").format(role, sql.SQL(role_attribute)))
        try:
            async with httpx.AsyncClient(headers={"Authorization": "Bearer " + http_server["token"]}) as client:
                async with streamable_http_client(http_server["url"], http_client=client) as (read, write, _):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        result = await session.call_tool("list_periods")
                        assert result.isError
                        assert "database_unavailable:" in result.content[0].text
                        assert "invalid_parameters" not in result.content[0].text
                        assert database["role"] not in result.content[0].text
        finally:
            admin.execute(sql.SQL("ALTER ROLE {} NOSUPERUSER NOBYPASSRLS").format(role))
