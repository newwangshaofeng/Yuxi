"""以固定业务题集执行 Harness² 风格可复现探针。"""

import hashlib
import json
import os
import time
from pathlib import Path

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


async def test_frozen_business_oracle(http_server):
    """重复三次真实 MCP 调用，分别统计正确性和结果一致性。"""
    path = Path(__file__).parent / "fixtures" / "business_cases.json"
    corpus = path.read_bytes()
    cases = json.loads(corpus)["cases"]
    split = os.environ.get("MINERAL_EVAL_SPLIT", "all")
    if split != "all":
        cases = [case for case in cases if case["split"] == split]
    assert cases, "评估集合不能为空"
    records = []
    async with httpx.AsyncClient(headers={"Authorization": "Bearer " + http_server["token"]}) as client:
        async with streamable_http_client(http_server["url"], http_client=client) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                for case in cases:
                    observations = []
                    timings = []
                    correct = []
                    for _ in range(3):
                        start = time.perf_counter()
                        result = await session.call_tool(case["tool"], case["args"])
                        timings.append(round((time.perf_counter() - start) * 1000, 3))
                        content = "\n".join(block.text for block in result.content if block.type == "text")
                        observation = {"is_error": result.isError, "facts": result.structuredContent}
                        if result.isError:
                            observation["error"] = content
                        observations.append(observation)
                        passed = result.isError == case.get("expect_error", False)
                        if case.get("expect_error"):
                            passed = passed and case.get("error_contains", "") in content
                        else:
                            for key, expected in case.get("checks", {}).items():
                                actual = result.structuredContent
                                try:
                                    for component in key.split("."):
                                        actual = actual[int(component)] if isinstance(actual, list) else actual[component]
                                    passed = passed and actual == expected
                                except (KeyError, IndexError, TypeError):
                                    passed = False
                        correct.append(passed)
                    records.append(
                        {
                            "case": case["name"],
                            "split": case["split"],
                            "correct_replays": sum(correct),
                            "stable": all(item == observations[0] for item in observations),
                            "observed": observations[0],
                            "latency_ms": timings,
                        }
                    )
    report = {
        "benchmark_sha256": hashlib.sha256(corpus).hexdigest(),
        "split": split,
        "cases": len(cases),
        "replays_per_case": 3,
        "correct_cases": sum(record["correct_replays"] == 3 for record in records),
        "correct_calls": sum(record["correct_replays"] for record in records),
        "stable_cases": sum(record["stable"] for record in records),
        "records": records,
    }
    output = os.environ.get("MINERAL_EVAL_OUTPUT")
    if output:
        Path(output).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    failures = [record["case"] for record in records if record["correct_replays"] != 3 or not record["stable"]]
    assert not failures, failures
