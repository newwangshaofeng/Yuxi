"""矿产规划首期统计角色。"""

from yuxi.modules.agents.presets import AgentPreset

PRESET = AgentPreset(
    slug="mineral-planning",
    name="矿产资源规划助手",
    description="查询 PG 基期矿山与矿权快照变化、矿种储量变化和年度开采量；需管理员配置 mineral-pg MCP。",
    backend_id="ChatbotAgent",
    context={
        "skills": ["mining-stat-analyst"],
        "preload_skills": ["mining-stat-analyst"],
    },
)
