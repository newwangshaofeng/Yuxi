"""提供带 Bearer 认证的 Streamable HTTP MCP。"""

import hmac
import os
from collections.abc import Awaitable
from typing import Annotated, Any

import psycopg
import uvicorn
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from pydantic import Field
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from mineral_pg.repository import EntityKind, MineralRepository, ReserveMetric

PeriodCode = Annotated[str, Field(strict=True, min_length=1, max_length=16)]
MineralId = Annotated[str, Field(strict=True, min_length=1, max_length=32)]
Limit = Annotated[int, Field(strict=True, ge=1, le=200)]
Offset = Annotated[int, Field(strict=True, ge=0, le=100000)]
Year = Annotated[int, Field(strict=True, ge=1900, le=2200)]


class MineralMCP(FastMCP):
    """未知参数显式报错，防止县级筛选等未支持条件被静默丢弃。"""

    async def list_tools(self):
        """为工具 schema 明确禁止额外字段。"""
        tools = await super().list_tools()
        for tool in tools:
            tool.inputSchema["additionalProperties"] = False
        return tools

    async def call_tool(self, name: str, arguments: dict):
        """在 SDK 类型校验前拒绝未声明的查询条件。"""
        tools = {tool.name: tool for tool in await self.list_tools()}
        if name in tools and set(arguments) - set(tools[name].inputSchema.get("properties", {})):
            raise ToolError("invalid_parameters: 不支持的额外参数；请检查工具 schema")
        return await super().call_tool(name, arguments)


class BearerAuth:
    """在 MCP 协议处理之前认证所有 HTTP 请求。"""

    def __init__(self, app: ASGIApp, token: str):
        """只接收高熵 ASCII 部署令牌，不记录凭据。"""
        if len(token) < 32 or not token.isascii() or any(character.isspace() for character in token):
            raise ValueError("MINERAL_PG_TOKEN 必须是至少 32 字符且不含空白的 ASCII 随机令牌")
        self.app = app
        self.expected = token.encode("ascii")

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        """拒绝缺失、错误或重复的认证头。"""
        if scope["type"] == "http":
            values = [value for key, value in scope["headers"] if key.lower() == b"authorization"]
            parts = values[0].split(b" ", 1) if len(values) == 1 else []
            if len(parts) != 2 or parts[0].lower() != b"bearer" or not hmac.compare_digest(parts[1], self.expected):
                response = JSONResponse({"error": "unauthorized"}, status_code=401, headers={"WWW-Authenticate": "Bearer"})
                await response(scope, receive, send)
                return
        await self.app(scope, receive, send)


def create_app(dsn: str, token: str) -> ASGIApp:
    """装配确定性统计工具，不提供 SQL 或数据写入入口。"""
    repository = MineralRepository(dsn)
    mcp = MineralMCP(
        "mineral-pg",
        instructions="矿产规划只读统计。先发现真实期次和矿种；缺少关键条件先追问。快照变化不代表法定矿权变更。",
        stateless_http=True,
        json_response=True,
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=["localhost", "localhost:*", "127.0.0.1", "127.0.0.1:*", "mineral-pg", "mineral-pg:*"],
        ),
    )
    annotations = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)

    @mcp.tool(annotations=annotations)
    async def list_periods() -> dict[str, Any]:
        """发现数据库实际期次与年份；比较只接受 status/base 基期，不能猜测示例年份。"""
        return await database_result(repository.list_periods())

    @mcp.tool(annotations=annotations)
    async def list_minerals(limit: Limit = 100, offset: Offset = 0) -> dict[str, Any]:
        """发现标准矿种名称与 mineral_id；按 has_more 分页，不自行编造矿种编码。"""
        return await database_result(repository.list_minerals(limit, offset))

    @mcp.tool(annotations=annotations)
    async def compare_entities(
        entity_kind: EntityKind,
        from_period: PeriodCode,
        to_period: PeriodCode,
        mineral_id: MineralId | None = None,
        limit: Limit = 100,
        offset: Offset = 0,
    ) -> dict[str, Any]:
        """比较两个基期的矿山、探矿权或采矿权快照。按稳定代理键匹配，证号换发只算属性变化；不推断注销/分立/探转采。"""
        return await database_result(repository.compare_entities(entity_kind, from_period, to_period, mineral_id, limit, offset))

    @mcp.tool(annotations=annotations)
    async def compare_reserves(
        from_period: PeriodCode,
        to_period: PeriodCode,
        mineral_id: MineralId | None = None,
        metric: ReserveMetric = "retained_reserves",
        limit: Limit = 100,
        offset: Offset = 0,
    ) -> dict[str, Any]:
        """比较全域矿种保有或累计查明储量。保留 NUMERIC 精度；缺期/NULL/未知或不同单位不计算差值；不支持行政区筛选。"""
        return await database_result(repository.compare_reserves(from_period, to_period, mineral_id, metric, limit, offset))

    @mcp.tool(annotations=annotations)
    async def annual_output(
        period_code: PeriodCode,
        start_year: Year,
        end_year: Year,
        mineral_id: MineralId | None = None,
        limit: Limit = 100,
        offset: Offset = 0,
    ) -> dict[str, Any]:
        """查询指定基期数据集中具体年度的开采总量 output_total。必须指定年份范围；不返回 stat_year=0 汇总值，不用设计产能代替。"""
        return await database_result(repository.annual_output(period_code, start_year, end_year, mineral_id, limit, offset))

    return BearerAuth(mcp.streamable_http_app(), token)


async def database_result(operation: Awaitable[dict]) -> dict:
    """把数据库故障转为稳定错误码，禁止泄露 SQL、DSN 或内部异常。"""
    try:
        return await operation
    except psycopg.errors.QueryCanceled:
        raise ToolError("query_timeout: 数据库查询超时；请缩小查询范围或联系管理员") from None
    except (PermissionError, psycopg.OperationalError):
        raise ToolError("database_unavailable: 数据库连接不可用；请联系管理员") from None
    except psycopg.Error:
        raise ToolError("query_failed: 数据库查询失败；请管理员核对 Schema 与只读授权") from None
    except ValueError as error:
        raise ToolError(f"invalid_parameters: {error}") from None


def main() -> None:
    """从环境加载部署配置并启动服务。"""
    dsn, token = os.environ.get("MINERAL_PG_DSN"), os.environ.get("MINERAL_PG_TOKEN")
    if not dsn or not token:
        raise ValueError("必须配置 MINERAL_PG_DSN 和 MINERAL_PG_TOKEN")
    uvicorn.run(create_app(dsn, token), host="0.0.0.0", port=8061, access_log=False)


if __name__ == "__main__":
    main()
