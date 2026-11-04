"""故障必须可区分且不泄漏内部数据库信息。"""

import os
import subprocess
import sys
from pathlib import Path

import psycopg
import pytest
from mcp.server.fastmcp.exceptions import ToolError

from mineral_pg.server import database_result


@pytest.mark.parametrize(
    ("error", "code"),
    [
        (psycopg.errors.QueryCanceled("internal secret DSN"), "query_timeout"),
        (psycopg.OperationalError("internal secret DSN"), "database_unavailable"),
        (PermissionError("internal secret role"), "database_unavailable"),
        (psycopg.errors.InsufficientPrivilege("internal secret SQL"), "query_failed"),
        (ValueError("矿种不存在"), "invalid_parameters"),
    ],
)
async def test_sanitized_failure_codes(error, code):
    """返回错误码且原始 DB 消息不进入工具结果。"""

    async def fail():
        """产生受控的目标故障。"""
        raise error

    with pytest.raises(ToolError, match=code) as exception:
        await database_result(fail())
    assert "internal secret" not in str(exception.value)


async def test_real_database_unavailable_is_not_empty():
    """无法连接的真实端口不是空数据。"""
    from mineral_pg.repository import MineralRepository

    with pytest.raises(ToolError, match="database_unavailable"):
        await database_result(MineralRepository("postgresql://invalid@127.0.0.1:1/absent").list_periods())


def test_ci_missing_database_is_not_green_skip():
    """真实 pytest 子进程证明 CI 缺失 PG 配置必须失败。"""
    environment = dict(os.environ, CI="true")
    environment.pop("MINERAL_TEST_ADMIN_DSN", None)
    target = str(Path(__file__).with_name("test_repository.py"))
    result = subprocess.run(
        [sys.executable, "-m", "pytest", target, "-q", "-k", "test_readonly_transaction_and_role"],
        env=environment,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 1
    assert "CI 必须配置 MINERAL_TEST_ADMIN_DSN" in result.stdout
