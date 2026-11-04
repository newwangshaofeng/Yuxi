# 矿产规划结构化统计 MCP

状态：implemented
类型：feature
Owner：packages/mineral-pg/src/mineral_pg/repository.py

## 问题

建设设想首期要求跨基期矿山与矿权变化、矿种储量变化、主要矿种年度开采量。用户提供的方案要求独立 Streamable HTTP MCP，不向模型开放 SQL。业务 DDL 的基期是 2020 与 2025；2021 是规划区间起点，不得冒充基期快照。

## 决策

### 实现方案

独立 Python 包 `packages/mineral-pg` 拥有只读 PG 查询、统计及 MCP 协议。Yuxi 通过已有远程 MCP 管理、Skill 依赖和预设 Agent 接入，不变更核心 runtime。共享 MCP 启用后对实例内所有可用 Agent 的用户开放，Bearer 认证授予整个 PG 角色可见数据集的访问权；没有成员级、部门级或行级授权。只允许在全体用户均有权读取该数据集的专用实例中启用；不同授权群体需要独立 Yuxi 实例及分别配置的端点、令牌、数据库角色，不能仅靠同实例多端点隔离。

调用链为领域 Skill → 类型化 MCP 工具 → 固定参数化 SQL → 只读 repeatable-read 事务 → 精确数值及口径元数据。代理键决定跨期对应，不从许可证号或名称猜测历史沿革；出现/缺失仅表示快照成员变化，不证明新设/注销。储量区分保有与累计查明，同矿种同单位且两边都有值才计算变化；年度值排除 stat_year=0。数据库错误不回传连接或 SQL 详情。

会话默认只读与显式事务只读共同实现同一项只读约束；验证最终事务状态和写入拒绝，不将两处设置计作两个独立安全边界。

服务为可选 Compose 组件，不自动加载 DDL 或更改生产数据，不自动创建共享 MCP。管理员登记并启用共享 MCP 是向整个实例开放该数据集的授权动作。

## 替代方案

本地工具无需额外进程，但不满足提供方案的独立 MCP 要求。通用 SQL MCP 更灵活，但无法约束统计口径。基于几何或名称自动构造沿革需要额外数据与确认，超出本期，不实现。

同实例成员授权需要可信调用者身份传递及 executor/repository 权限复核，不能靠 Skill 提示词或界面隐藏实现；当前没有该能力，不将其描述为已实现。

## 验证

| 验收主张 | 失败面 | 语义 Owner | 直接证据 / 命令 | 负向案例 | 当前结果 |
|---|---|---|---|---|---|
| 只读参数化查询 | 注入/写入 | mineral_pg.repository | package pytest integration | 默认可写且已授权 DELETE 的角色仍被事务拒绝；超级用户/BYPASSRLS；注入 | Passed |
| 基期与代理键口径 | 错期/证号换发 | mineral_pg.repository | package pytest | 单年规划类型/角色分别拒绝；多年基期、无年份基期；代理键稳定换证 | Passed |
| 精确且可比储量 | 混单位/NULL/零 | mineral_pg.results | package pytest | 单位改变、缺期、零基数 | Passed |
| 年度不混期次汇总 | stat_year=0/跨期混行 | mineral_pg.repository | package pytest integration；按期次独立 SQL oracle | 同年不同期次含异单位干扰行、汇总大值与年度并存 | Passed |
| MCP 认证及契约 | 未认证/无效参数/配置错误 | mineral_pg.server | 真实 HTTP MCP client | 错误 Token、超限请求；超级用户/BYPASSRLS 返回 database_unavailable | Passed |

## 后果

原方案的租户级隔离尚未满足，专用实例部署是否满足首期验收需要用户明确确认；确认前不得视为权限验收通过或向多租户实例开放。行政区查询、法定整合/分立/探转采识别、规划指标上限与执行占比、规划基底统计不在本期工具范围。

没有真实业务数据和模型凭据，合成 PG 与协议重放不能替代真实数据核验或自然语言意图识别准确率。若实际入库未按 DDL 约定复用跨期代理键，必须先清理身份映射，服务不猜测。PG 共享汇总储量表没有行政区字段，不提供伪造的县级筛选。
