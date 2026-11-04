# 矿产规划 PG MCP

面向 Yuxi 部署管理员。服务覆盖首期三个 PG 场景：跨基期矿山/探矿权/采矿权快照、矿种储量、具体年度开采量。不执行 GIS、ETL、数据修改或任意 SQL。完整输入 schema 以 MCP `tools/list` 为准；业务解释由内置 `mining-stat-analyst` Skill 拥有。

## 部署与接入

1. 使用已按用户提供的 DDL 建立并导入数据的专用矿产数据库（PostgreSQL 14+ / PostGIS 3.x）。**服务不自动执行建库、DDL 或导入**；测试目录的完整 DDL 和数据只用于隔离测试。
2. 由数据库管理员创建非超级用户、无 BYPASSRLS 的只读登录角色；只授权 `public` schema 的 USAGE，以及 `dim_period`、`dim_mineral`、`fact_mine`、`fact_mine_mineral`、`fact_explore_right`、`fact_mining_right`、`fact_mineral_reserve`、`fact_mineral_develop` 的 SELECT，不授予 CREATE/INSERT/UPDATE/DELETE 或其他对象的执行权限。建议角色默认 `default_transaction_read_only=on`。跨机器数据库连接使用 TLS 校验并限制网络来源。
3. 在私有部署环境设置 `MINERAL_PG_DSN` 与 `MINERAL_PG_TOKEN`。Token 使用密码管理器产生至少 32 字符 ASCII 随机值，不写进 prompt、源码或日志。DSN 使用只读角色，不使用 Yuxi 元数据数据库账号。
4. 在仓库根目录启动可选组件：

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.mineral.yml --profile mineral up -d mineral-pg
   ```

   完整 Yuxi `.env` 仍需按平台安装文档配置；本 overlay 不启动 PostgreSQL，也不创建测试库。进程监听 8061，宿主机只绑定回环地址。生产访问应经受控网络/TLS 代理；内部 HTTP 信任域不得包含未授权工作负载。
5. 在 Yuxi 的 MCP 管理界面新建 **共享 MCP**，标识必须为 `mineral-pg`，传输为 `streamable_http`，URL 为 `http://mineral-pg:8061/mcp`，认证头为 `Authorization: Bearer <部署令牌>`。该地址适用于同一个 Compose app-network；平台在容器外时使用实际可达地址。服务 Host 白名单只接受 `mineral-pg`、`localhost`、`127.0.0.1`，反向代理须转发内部 Host，不开放浏览器跨域 Origin。
6. **启用共享 MCP 后，实例内所有能使用 Agent 的用户都能读取该 PG 角色可见的完整数据集。现有接入没有成员级、部门级或行级隔离。** 只有实例内全体用户均获授权时才能启用「矿产资源规划助手」。不同授权群体必须使用独立的 Yuxi 实例，并分别配置端点、令牌与最小权限 PG 角色；仅在同一实例增加多个端点不能隔离用户。此模式不满足同实例多租户隔离要求；原方案的租户隔离尚未验收，不得在多租户共享实例接入受限矿产数据。

该 overlay 的必填变量在 Compose 解析时检查：只要指定此文件，即使没有启用 mineral profile 也必须设置 DSN/token；默认拓扑无需引用它。

## 数据口径与错误

先通过字典发现真实基期和矿种；DDL 默认基期是 2020 和 2025，不能把规划期 2021—2025 视作 2021 现状快照。入库必须跨期复用 `mine_id` / `right_id`；服务不猜测名称、证号或空间沿革。实体变化不比较几何，出现/缺失不是法律上的新设/注销。

储量只在两期均有记录、均非 NULL、单位明确一致时计算后期减前期。NUMERIC 以精确十进制字符串输出；百分比四位小数，采用 Decimal 默认半偶舍入（ROUND_HALF_EVEN，银行家舍入），零基数比例为空。产量只读取 `stat_year>0` 的 `output_total`；缺年不补零，多个矿种不合计。所有列表均有上限；明细翻页不能替代全量 summary。储量和年度表没有行政区维度，不提供该筛选。

未认证请求返回 HTTP 401。工具错误保留 MCP `isError`，并区分 `invalid_parameters`、`database_unavailable`、`query_timeout` 与 `query_failed`；数据库错误不暴露 SQL、DSN 或连接详情。成功空列表不是错误；调用方必须保留这一区别。连接时限为 5 秒，每条 SQL 的数据库执行时限为 10 秒，每次调用使用只读 repeatable-read 事务。

## 验证

Python 3.12/3.13；依赖由本包 `uv.lock` 固定：

```bash
uv sync --project packages/mineral-pg --locked
uv run --project packages/mineral-pg ruff check packages/mineral-pg
uv run --project packages/mineral-pg ruff format packages/mineral-pg --check
uv run --project packages/mineral-pg ty check packages/mineral-pg/src
uv build --project packages/mineral-pg
uv run --project packages/mineral-pg pytest packages/mineral-pg/tests -q
```

完整 PG/MCP 测试需要专用可创建数据库和角色的 PostGIS 测试实例，通过 `MINERAL_TEST_ADMIN_DSN` 提供管理员连接。fixture 创建随机独立数据库、加载原始 DDL 与合成数据、创建只读角色，结束后删除自己创建的库和角色。**不要指向生产实例**。本地没有此变量时 integration 会明确 skip，不能宣称 PG/HTTP 已验证；`CI=true` 时缺失此变量直接失败。CI 使用独立 PostGIS service 强制执行。

Harness² 风格业务回归固定在 `tests/fixtures/business_cases.json`，由 `tests/test_evaluation.py` 通过真实 HTTP MCP 重放，`MINERAL_EVAL_OUTPUT` 可指定结果 JSON 输出路径。题集 oracle 手工冻结且只读；不能在 CI 里从被测实现生成标准答案。回归只验证结构化工具事实及稳定性，**不代表真实业务数据或自然语言模型端到端准确率**。
