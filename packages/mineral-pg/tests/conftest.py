"""隔离 PostgreSQL 数据库与只读业务角色。"""

import os
import secrets
import socket
import threading
import uuid
from pathlib import Path

import psycopg
import pytest
import uvicorn
from psycopg import sql
from psycopg.conninfo import make_conninfo

from mineral_pg.repository import MineralRepository
from mineral_pg.server import create_app


@pytest.fixture(scope="session")
def database():
    """只在专用测试实例创建并清理随机命名数据库，不触碰现有业务数据。"""
    admin = os.environ.get("MINERAL_TEST_ADMIN_DSN")
    if not admin:
        if os.environ.get("CI") == "true":
            pytest.fail("CI 必须配置 MINERAL_TEST_ADMIN_DSN；不得把 PG 集成静默跳过")
        pytest.skip("MINERAL_TEST_ADMIN_DSN 未配置；真实 PG 集成未运行")
    suffix = uuid.uuid4().hex[:12]
    name, role = "mineral_test_" + suffix, "mineral_ro_" + suffix
    password = secrets.token_urlsafe(32)
    with psycopg.connect(admin, autocommit=True) as connection:
        connection.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(name)))
        connection.execute(sql.SQL("CREATE ROLE {} LOGIN PASSWORD {}").format(sql.Identifier(role), sql.Literal(password)))
        connection.execute(sql.SQL("ALTER ROLE {} SET default_transaction_read_only=on").format(sql.Identifier(role)))
    owner_dsn = make_conninfo(admin, dbname=name)
    readonly_dsn = make_conninfo(owner_dsn, user=role, password=password)
    try:
        with psycopg.connect(owner_dsn, autocommit=True) as connection:
            fixtures = Path(__file__).parent / "fixtures"
            connection.execute((fixtures / "schema.sql").read_text())
            connection.execute((fixtures / "data.sql").read_text())
            connection.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(sql.Identifier(role)))
            connection.execute(
                sql.SQL(
                    "GRANT SELECT ON dim_period, dim_mineral, fact_mine, fact_mine_mineral, fact_explore_right, "
                    "fact_mining_right, fact_mineral_reserve, fact_mineral_develop TO {}"
                ).format(sql.Identifier(role))
            )
        yield {"owner": owner_dsn, "readonly": readonly_dsn, "admin": admin, "role": role}
    finally:
        with psycopg.connect(admin, autocommit=True) as connection:
            connection.execute(sql.SQL("DROP DATABASE {} WITH (FORCE)").format(sql.Identifier(name)))
            connection.execute(sql.SQL("DROP ROLE {}").format(sql.Identifier(role)))


@pytest.fixture
def repository(database):
    """提供真实只读数据访问入口。"""
    return MineralRepository(database["readonly"])


@pytest.fixture(scope="session")
def http_server(database):
    """用真实 TCP HTTP 承载完整 MCP 生命周期。"""
    token = secrets.token_urlsafe(32)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(128)
        port = listener.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(create_app(database["readonly"], token), log_level="critical", access_log=False))
        thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
        thread.start()
        # Uvicorn signals startup only after the ASGI lifespan has completed.
        import time

        deadline = time.monotonic() + 10
        while not server.started and thread.is_alive() and time.monotonic() < deadline:
            threading.Event().wait(0.01)
        assert server.started, "MCP HTTP server did not start"
        try:
            yield {"url": f"http://127.0.0.1:{port}/mcp", "token": token}
        finally:
            server.should_exit = True
            thread.join(timeout=10)
            assert not thread.is_alive()
